defmodule WallopCore.Entropy.EntropyWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.{DrandClient, EntropyWorker, WeatherClient}

  @drand_randomness "a" <> String.duplicate("0", 63)
  @drand_signature "abcdef1234567890"
  @weather_pressure 1013.4

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
      draw = create_draw(api_key, %{skip_entropy: false})

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
      assert completed.weather_value == "1013"
      assert completed.weather_raw != nil
      assert completed.executed_at != nil
      assert completed.results != nil
      assert length(completed.results) == draw.winner_count

      # Verify results match FairPick.draw directly
      atom_entries = WallopCore.Entries.to_atom_keys(draw.entries)

      {seed_bytes, _seed_json} =
        WallopCore.Protocol.compute_seed(draw.entry_hash, @drand_randomness, "1013")

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
          skip_entropy: false,
          callback_url: "https://example.com/hook"
        })

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      assert [webhook_job] = all_enqueued(worker: WallopCore.Entropy.WebhookWorker)
      assert webhook_job.args["draw_id"] == draw.id
      assert webhook_job.args["callback_url"] == "https://example.com/hook"
    end

    test "does not enqueue webhook when callback_url is nil" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: false})

      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      assert [] = all_enqueued(worker: WallopCore.Entropy.WebhookWorker)
    end
  end

  describe "drand unavailable" do
    test "snoozes when drand returns error" do
      stub_drand_error()

      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: false})

      job = fake_job(draw)
      assert {:snooze, seconds} = EntropyWorker.perform(job)
      assert is_integer(seconds) and seconds > 0

      reloaded = reload_draw(draw, api_key)
      # Should be pending_entropy (transitioned) but not completed
      assert reloaded.status == :pending_entropy
    end
  end

  describe "weather unavailable" do
    test "snoozes when weather returns error" do
      stub_weather_error()

      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: false})

      job = fake_job(draw)
      assert {:snooze, seconds} = EntropyWorker.perform(job)
      assert is_integer(seconds) and seconds > 0
    end
  end

  describe "already completed" do
    test "returns :ok for completed draw (idempotent)" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: false})

      # First execution completes the draw
      job = fake_job(draw)
      assert :ok = EntropyWorker.perform(job)

      completed = reload_draw(draw, api_key)
      assert completed.status == :completed

      # Second execution is a no-op
      assert :ok = EntropyWorker.perform(job)
    end
  end

  describe "entry hash re-verification" do
    test "execute_with_entropy change rejects mismatched entry hash" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: false})

      # Transition to pending_entropy so the execute_with_entropy action can fire
      {:ok, draw} =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      # Build a draw struct with a bogus entry_hash in memory to simulate mismatch.
      # The changeset.data will have the wrong hash, triggering the integrity check.
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
          weather_value: "1013",
          weather_raw: "{}"
        })
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      assert {:error, _} = result
    end
  end

  describe "failure timeout" do
    test "marks draw as failed when job was inserted 25 hours ago" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: false})

      # Build a job that appears to have been inserted 25 hours ago
      old_inserted_at = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      job = fake_job(draw, inserted_at: old_inserted_at)

      assert :ok = EntropyWorker.perform(job)

      failed = reload_draw(draw, api_key)
      assert failed.status == :failed
      assert failed.failed_at != nil
      assert failed.failure_reason =~ "timed out"
    end
  end

  # -- Helpers --

  defp fake_job(draw, opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    %Oban.Job{
      args: %{"draw_id" => draw.id},
      inserted_at: inserted_at
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

  defp stub_drand_error do
    Req.Test.stub(DrandClient, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)
  end

  defp stub_weather_success do
    Req.Test.stub(WeatherClient, fn conn ->
      body = %{
        "type" => "FeatureCollection",
        "features" => [
          %{
            "type" => "Feature",
            "geometry" => %{"type" => "Point", "coordinates" => [-1.5714, 51.1486]},
            "properties" => %{
              "requestPointDistance" => 0.0,
              "modelRunDate" => "2025-01-15T12:00Z",
              "timeSeries" =>
                Enum.map(0..23, fn hour ->
                  %{
                    "time" =>
                      "2025-01-15T#{String.pad_leading(Integer.to_string(hour), 2, "0")}:00Z",
                    "mslp" => @weather_pressure
                  }
                end) ++
                  generate_future_hours()
            }
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  defp stub_weather_error do
    Req.Test.stub(WeatherClient, fn conn ->
      Plug.Conn.send_resp(conn, 500, "internal error")
    end)
  end

  # Generate weather data for many future hours to cover any weather_time
  defp generate_future_hours do
    now = DateTime.utc_now()
    base_date = Date.utc_today()

    for day_offset <- 0..3,
        hour <- 0..23,
        dt = build_utc_datetime(Date.add(base_date, day_offset), hour),
        DateTime.compare(dt, now) == :gt do
      %{
        "time" => Calendar.strftime(dt, "%Y-%m-%dT%H:00Z"),
        "mslp" => @weather_pressure
      }
    end
  end

  defp build_utc_datetime(date, hour) do
    {:ok, dt} = DateTime.new(date, Time.new!(hour, 0, 0), "Etc/UTC")
    dt
  end
end
