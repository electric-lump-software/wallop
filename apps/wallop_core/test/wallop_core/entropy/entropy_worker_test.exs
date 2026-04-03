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
      assert completed.drand_response != nil
      assert completed.weather_value == "101340"
      assert completed.weather_raw != nil
      assert completed.weather_observation_time != nil
      assert completed.weather_fallback_reason == nil
      assert completed.executed_at != nil
      assert completed.results != nil
      assert length(completed.results) == draw.winner_count

      # Verify results match FairPick.draw directly
      atom_entries = WallopCore.Entries.load_for_draw(draw.id)

      {seed_bytes, _seed_json} =
        WallopCore.Protocol.compute_seed(draw.entry_hash, @drand_randomness, "101340")

      expected_results = FairPick.draw(atom_entries, seed_bytes, draw.winner_count)

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
      assert completed.weather_fallback_reason =~ "unexpected_status"

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
      assert completed.weather_fallback_reason =~ "401"
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

  describe "max attempts exhausted" do
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

  defp stub_drand_success do
    Req.Test.stub(DrandClient, fn conn ->
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
    end)
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
