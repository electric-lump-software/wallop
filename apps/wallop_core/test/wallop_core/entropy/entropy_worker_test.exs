defmodule WallopCore.Entropy.EntropyWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.{DrandClient, EntropyWorker, WeatherClient}

  @drand_randomness "a" <> String.duplicate("0", 63)
  @drand_signature "abcdef1234567890"
  @weather_pressure 101_340

  setup do
    stub_drand_success()
    stub_weather_success()
    ensure_infrastructure_key()

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    Application.put_env(:wallop_core, WeatherClient,
      plug: {Req.Test, WeatherClient},
      req_options: [retry: false]
    )

    Application.put_env(:wallop_core, :met_office_api_key, "test-api-key")

    on_exit(fn ->
      Application.delete_env(:wallop_core, DrandClient)
      Application.delete_env(:wallop_core, WeatherClient)
    end)

    :ok
  end

  describe "happy path" do
    test "completes draw with entropy-derived seed" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.status == :awaiting_entropy

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed
      assert completed.seed_source == :entropy
      assert completed.seed != nil
      assert completed.seed_json != nil
      assert completed.drand_randomness == @drand_randomness
      assert completed.drand_signature == @drand_signature
      # The relay's body as decoded and re-encoded, unchanged for forecast
      # draws.
      assert completed.drand_response ==
               Jason.encode!(%{
                 "randomness" => @drand_randomness,
                 "signature" => @drand_signature,
                 "round" => draw.drand_round
               })

      assert completed.weather_value == "101340"
      assert completed.weather_raw != nil
      assert completed.weather_observation_time != nil
      assert completed.weather_fallback_reason == nil
      assert completed.executed_at != nil
      assert completed.results != nil
      assert length(completed.results) == draw.winner_count

      # Verify results match FairPick.draw directly
      entries = WallopCore.Entries.load_for_draw(draw.id)
      fair_pick_entries = Enum.map(entries, &%{id: &1.uuid, weight: &1.weight})

      {seed_bytes, _seed_json} =
        WallopCore.Protocol.compute_seed(draw.entry_hash, @drand_randomness, "101340")

      expected_results = FairPick.draw(fair_pick_entries, seed_bytes, draw.winner_count)

      expected_string_results =
        Enum.map(expected_results, fn %{position: pos, entry_id: id} ->
          %{"position" => pos, "entry_id" => id}
        end)

      assert completed.results == expected_string_results
    end

    test "enqueues webhook when callback_url is set" do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          entropy: true,
          callback_url: "https://example.com/hook"
        })

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      assert [webhook_job] = all_enqueued(worker: WallopCore.Entropy.WebhookWorker)
      assert webhook_job.args["draw_id"] == draw.id
      assert webhook_job.args["api_key_id"] == draw.api_key_id
    end

    test "does not enqueue webhook when callback_url is nil" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      assert [] = all_enqueued(worker: WallopCore.Entropy.WebhookWorker)
    end
  end

  describe "no BLS check on the forecast path" do
    # Forecast draws keep their behaviour this release: their drand beacon
    # is not BLS-checked. Traced, not inferred: no function of the check,
    # its NIF or the test wrapper is called while a forecast draw executes,
    # here with a signature that would never verify.
    @bls_modules [WallopCore.Drand.Bls, WallopCore.Drand.Bls.Native, WallopCore.Test.DrandBls]

    setup do
      # A module must be loaded for its pattern to take; each must match.
      for m <- @bls_modules do
        Code.ensure_loaded!(m)
        assert :erlang.trace_pattern({m, :_, :_}, true, [:global]) > 0
      end

      # A process can't be its own call tracer: a forwarder relays the
      # trace messages to the test.
      test_pid = self()
      tracer = spawn_link(fn -> forward_traces(test_pid) end)
      :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}])

      on_exit(fn ->
        for m <- @bls_modules, do: :erlang.trace_pattern({m, :_, :_}, false, [:global])
      end)
    end

    test "a forecast draw completes without any BLS call" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert :ok = EntropyWorker.perform(fake_job(draw))
      :erlang.trace(self(), false, [:call, :set_on_spawn])

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed
      assert completed.drand_signature == @drand_signature
      # Trace messages are sent asynchronously: give them time to arrive.
      Process.sleep(50)
      # Only the BLS modules are traced, so any call message is a BLS call.
      refute_received {:traced, _}
    end

    test "the trace does see a BLS call when one is made (control)" do
      Req.Test.stub(DrandClient, fn conn ->
        Req.Test.json(conn, %{
          "round" => 1000,
          "randomness" => @drand_randomness,
          "signature" => String.duplicate("ab", 48)
        })
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_response} =
                 DrandClient.fetch_with_failover(DrandClient.quicknet_chain_hash(), 1000,
                   verify_bls: true
                 )
      end)

      :erlang.trace(self(), false, [:call, :set_on_spawn])

      assert_receive {:traced,
                      {:trace, _, :call, {WallopCore.Test.DrandBls, :verify_quicknet, _}}}
    end
  end

  defp forward_traces(test_pid) do
    receive do
      msg -> send(test_pid, {:traced, msg})
    end

    forward_traces(test_pid)
  end

  describe "transient errors (phase 1)" do
    test "returns error when drand unavailable (triggers Oban retry)" do
      stub_drand_error(:not_found)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 1)
      assert {:error, _} = EntropyWorker.perform(job)

      reloaded = reload_draw(draw, api_key)
      assert reloaded.status == :pending_entropy
    end

    test "returns error when weather unavailable in phase 1" do
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 3)
      assert {:error, _} = EntropyWorker.perform(job)
    end

    test "returns error when both sources fail" do
      stub_drand_error(:not_found)
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 1)
      assert {:error, _} = EntropyWorker.perform(job)

      reloaded = reload_draw(draw, api_key)
      assert reloaded.status == :pending_entropy
    end
  end

  describe "drand-only fallback (phase 2)" do
    test "falls back to drand-only when weather fails after threshold" do
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 6)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed
      assert completed.seed_source == :entropy
      assert completed.drand_randomness != nil
      assert completed.weather_value == nil
      assert completed.weather_fallback_reason == "unreachable"

      # Verify seed uses drand-only computation
      {expected_seed, _} =
        WallopCore.Protocol.compute_seed(completed.entry_hash, completed.drand_randomness)

      assert completed.seed == Base.encode16(expected_seed, case: :lower)
    end

    # @weather_attempt_threshold is 5 — attempt 5 is the boundary
    test "falls back at exactly the threshold (attempt 5)" do
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 5)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed
      assert completed.weather_value == nil
      assert completed.weather_fallback_reason != nil
    end

    test "does not fall back before threshold (attempt 4)" do
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 4)
      assert {:error, _} = EntropyWorker.perform(job)

      reloaded = reload_draw(draw, api_key)
      assert reloaded.status == :pending_entropy
    end

    test "does not fall back if drand also failed" do
      stub_drand_error(:not_found)
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      # Both failed at attempt 6 — should retry, not fallback
      job = fake_job(draw, attempt: 6)
      assert {:error, _} = EntropyWorker.perform(job)
    end
  end

  describe "permanent errors" do
    test "weather 401 triggers drand-only fallback at threshold, not draw failure" do
      stub_weather_error(401)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      # At threshold, weather auth failure triggers drand-only
      job = fake_job(draw, attempt: 5)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed
      assert completed.weather_value == nil
      assert completed.weather_fallback_reason == "unreachable"
    end

    test "weather 401 retries before threshold" do
      stub_weather_error(401)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 1)
      assert {:error, _} = EntropyWorker.perform(job)

      reloaded = reload_draw(draw, api_key)
      assert reloaded.status == :pending_entropy
    end

    test "drand 401 fails draw immediately" do
      stub_drand_error(:unauthorized)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      failed = reload_draw(draw, api_key)
      assert failed.status == :failed
      assert failed.failure_reason =~ "drand"
    end
  end

  describe "a drand body that isn't a JSON object, or is over the cap" do
    # A malformed body (a CDN glitch, a captive portal, a hostile relay) is
    # transient on the forecast path: the client fails over to the next
    # relay, and if every relay sends one the job retries, as for a network
    # error. It used to crash the job; it never fails the draw at once.
    for {label, respond} <- [
          {"a JSON array", quote(do: &Req.Test.json(&1, []))},
          {"an HTML page",
           quote(
             do:
               &(&1
                 |> Plug.Conn.put_resp_content_type("text/html")
                 |> Plug.Conn.send_resp(200, "<html>captive portal</html>"))
           )},
          {"a body over 16 KiB",
           quote(
             do: fn conn ->
               round = conn.path_info |> List.last() |> String.to_integer()

               Req.Test.json(conn, %{
                 "round" => round,
                 "randomness" => "a" <> String.duplicate("0", 63),
                 "signature" => "abcdef1234567890",
                 "pad" => String.duplicate("0", 20_000)
               })
             end
           )}
        ] do
      test "#{label} from every relay is retried, and the draw is not failed" do
        Req.Test.stub(DrandClient, unquote(respond))

        api_key = create_api_key()
        draw = create_draw(api_key, %{entropy: true})

        for attempt <- [1, 9] do
          assert {:error, _} = EntropyWorker.perform(fake_job(draw, attempt: attempt))
          assert reload_draw(draw, api_key).status in [:awaiting_entropy, :pending_entropy]
        end
      end

      test "#{label} from the first relay moves on to the next, which completes the draw" do
        respond = unquote(respond)

        Req.Test.stub(DrandClient, fn conn ->
          if conn.host == "api.drand.sh", do: respond.(conn), else: honest_drand(conn)
        end)

        api_key = create_api_key()
        draw = create_draw(api_key, %{entropy: true})

        assert :ok = EntropyWorker.perform(fake_job(draw))
        assert reload_draw(draw, api_key).status == :completed
      end
    end

    test "an invalid beacon (a JSON object with the wrong round) is still permanent" do
      Req.Test.stub(DrandClient, fn conn ->
        Req.Test.json(conn, %{
          "round" => 1,
          "randomness" => @drand_randomness,
          "signature" => @drand_signature
        })
      end)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert :ok = EntropyWorker.perform(fake_job(draw))
      failed = reload_draw(draw, api_key)
      assert failed.status == :failed
      assert failed.failure_reason =~ "drand"
    end
  end

  describe "max attempts exhausted" do
    test "the public failure reason is fixed text; the detail is only logged" do
      stub_drand_error(:not_found)
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = EntropyWorker.perform(fake_job(draw, attempt: 10))
        end)

      failed = reload_draw(draw, api_key)
      assert failed.failure_reason == "drand unavailable after 10 attempts"
      refute failed.failure_reason =~ ~r/[{}%]/
      assert log =~ "drand unavailable after 10 attempts"
    end

    test "fails draw on final attempt when drand unavailable" do
      stub_drand_error(:not_found)
      stub_weather_error(500)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw, attempt: 10)
      assert :ok = EntropyWorker.perform(job)

      failed = reload_draw(draw, api_key)
      assert failed.status == :failed
      assert failed.failure_reason =~ "drand unavailable"
    end

    test "enqueues webhook on final attempt failure" do
      stub_drand_error(:not_found)
      stub_weather_error(500)

      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          entropy: true,
          callback_url: "https://example.com/hook"
        })

      job = fake_job(draw, attempt: 10)
      assert :ok = EntropyWorker.perform(job)

      assert [webhook_job] = all_enqueued(worker: WallopCore.Entropy.WebhookWorker)
      assert webhook_job.args["draw_id"] == draw.id
    end
  end

  describe "already completed" do
    test "returns :ok for completed draw (idempotent)" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed

      assert :ok = EntropyWorker.perform(job)
    end
  end

  describe "entry hash re-verification" do
    test "execute_with_entropy change rejects mismatched entry hash" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      {:ok, draw} =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      tampered_draw = %{
        draw
        | entry_hash: "0000000000000000000000000000000000000000000000000000000000000000"
      }

      result =
        tampered_draw
        |> Ash.Changeset.for_update(:execute_with_entropy, %{
          drand_randomness: @drand_randomness,
          drand_signature: @drand_signature,
          drand_response: "{}",
          weather_value: "101340",
          weather_raw: "{}",
          weather_observation_time: DateTime.utc_now()
        })
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      assert {:error, _} = result
    end
  end

  describe "already pending_entropy" do
    test "draw already in pending_entropy skips transition and still completes" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      {:ok, pending_draw} =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      assert pending_draw.status == :pending_entropy

      job = fake_job(pending_draw)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(pending_draw, api_key)
      assert completed.status == :completed
    end
  end

  describe "losing a race to a finished draw" do
    test "is success when the draw is already terminal" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      draw
      |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "other worker"})
      |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert :ok = EntropyWorker.settle_after_error(draw.id, :stale)
    end

    test "is still an error when the draw is not terminal" do
      api_key = create_api_key()
      draw = create_draw(api_key)
      assert {:error, :stale} = EntropyWorker.settle_after_error(draw.id, :stale)
    end
  end

  # -- Helpers --

  defp fake_job(draw, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)

    %Oban.Job{
      args: %{"draw_id" => draw.id},
      attempt: attempt,
      max_attempts: 10
    }
  end

  defp reload_draw(draw, api_key) do
    Ash.get!(WallopCore.Resources.Draw, draw.id,
      domain: WallopCore.Domain,
      actor: api_key
    )
  end

  defp stub_drand_success, do: Req.Test.stub(DrandClient, &honest_drand/1)

  defp honest_drand(conn) do
    round =
      conn.request_path
      |> String.split("/")
      |> List.last()
      |> String.to_integer()

    body = %{
      "randomness" => @drand_randomness,
      "signature" => @drand_signature,
      "round" => round
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp stub_drand_error(:not_found) do
    Req.Test.stub(DrandClient, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)
  end

  defp stub_drand_error(:unauthorized) do
    Req.Test.stub(DrandClient, fn conn ->
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end)
  end

  defp stub_weather_success do
    Req.Test.stub(WeatherClient, fn conn ->
      now = DateTime.utc_now()

      times =
        for offset <- -1..4 do
          time = DateTime.add(now, offset * 300, :second)
          %{"time" => Calendar.strftime(time, "%Y-%m-%dT%H:%MZ"), "mslp" => @weather_pressure}
        end

      body = %{
        "type" => "FeatureCollection",
        "features" => [
          %{
            "type" => "Feature",
            "geometry" => %{"type" => "Point", "coordinates" => [-1.5714, 51.1486]},
            "properties" => %{
              "requestPointDistance" => 0.0,
              "modelRunDate" => "2025-01-15T12:00Z",
              "timeSeries" => times
            }
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  defp stub_weather_error(status) do
    Req.Test.stub(WeatherClient, fn conn ->
      Plug.Conn.send_resp(conn, status, "error")
    end)
  end
end
