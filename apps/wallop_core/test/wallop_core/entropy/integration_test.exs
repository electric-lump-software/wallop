defmodule WallopCore.Entropy.IntegrationTest do
  @moduledoc """
  End-to-end test: create draw → entropy worker → completed with correct results.

  Verifies that the full entropy pipeline produces results matching
  FairPick.draw/3 called directly with the same seed.
  """
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.{DrandClient, EntropyWorker, WeatherClient}

  @drand_randomness "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  @drand_signature "deadbeef" <> String.duplicate("00", 44)
  @weather_pressure 101_350

  setup do
    # Stub drand to return a known randomness value
    Req.Test.stub(DrandClient, fn conn ->
      round = conn.path_info |> List.last() |> String.to_integer()

      Req.Test.json(conn, %{
        "round" => round,
        "randomness" => @drand_randomness,
        "signature" => @drand_signature
      })
    end)

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    # Stub weather to return a known pressure. Includes entries at 5-minute
    # intervals around now so the target_time filter always finds a match
    # that's after draw.inserted_at (required by the timing validation).
    Req.Test.stub(WeatherClient, fn conn ->
      now = DateTime.utc_now()

      # Generate entries every 5 minutes from now-5min to now+20min
      # This ensures there's always an entry after draw creation and
      # within 1 hour of weather_time (~10 min from draw creation)
      times =
        for offset <- -1..4 do
          time = DateTime.add(now, offset * 300, :second)
          %{"time" => Calendar.strftime(time, "%Y-%m-%dT%H:%MZ"), "mslp" => @weather_pressure}
        end

      Req.Test.json(conn, %{
        "type" => "FeatureCollection",
        "features" => [
          %{
            "properties" => %{
              "timeSeries" => times
            }
          }
        ]
      })
    end)

    Application.put_env(:wallop_core, WeatherClient,
      req_options: [plug: {Req.Test, WeatherClient}, retry: false]
    )

    ensure_infrastructure_key()

    on_exit(fn ->
      Application.delete_env(:wallop_core, DrandClient)
      Application.delete_env(:wallop_core, WeatherClient)
    end)

    :ok
  end

  describe "full entropy pipeline" do
    test "create → entropy worker → completed with correct results" do
      api_key = create_api_key()

      # Create draw with entropy (entropy: true)
      draw =
        create_draw(api_key, %{
          entries: [
            %{"id" => "alice", "weight" => 1},
            %{"id" => "bob", "weight" => 1},
            %{"id" => "charlie", "weight" => 3}
          ],
          winner_count: 2,
          entropy: true
        })

      assert draw.status == :awaiting_entropy
      assert draw.drand_round != nil
      assert draw.drand_chain == DrandClient.quicknet_chain_hash()
      assert draw.weather_time != nil

      # Run the entropy worker manually
      job = %Oban.Job{
        args: %{"draw_id" => draw.id},
        attempt: 1,
        max_attempts: 10
      }

      assert :ok = EntropyWorker.perform(job)

      # Reload the draw
      completed =
        Ash.get!(WallopCore.Resources.Draw, draw.id,
          domain: WallopCore.Domain,
          authorize?: false
        )

      assert completed.status == :completed
      assert completed.seed_source == :entropy
      assert completed.seed != nil
      assert completed.seed_json != nil
      assert completed.drand_randomness == @drand_randomness
      assert completed.weather_value == "101350"
      assert completed.executed_at != nil
      assert completed.results != nil
      assert length(completed.results) == 2

      # Verify results match FairPick.draw/3 directly
      atom_entries = WallopCore.Entries.load_for_draw(completed.id)
      seed_bytes = Base.decode16!(completed.seed, case: :mixed)
      expected_results = FairPick.draw(atom_entries, seed_bytes, completed.winner_count)

      expected_json =
        Enum.map(expected_results, fn %{position: pos, entry_id: id} ->
          %{"position" => pos, "entry_id" => id}
        end)

      assert completed.results == expected_json
    end

    test "seed_json contains the JCS-canonical entropy inputs" do
      api_key = create_api_key()

      draw = create_draw(api_key, %{entropy: true})

      job = %Oban.Job{
        args: %{"draw_id" => draw.id},
        attempt: 1,
        max_attempts: 10
      }

      assert :ok = EntropyWorker.perform(job)

      completed =
        Ash.get!(WallopCore.Resources.Draw, draw.id,
          domain: WallopCore.Domain,
          authorize?: false
        )

      # seed_json should be valid JSON with the three entropy inputs
      seed_data = Jason.decode!(completed.seed_json)
      assert Map.has_key?(seed_data, "drand_randomness")
      assert Map.has_key?(seed_data, "entry_hash")
      assert Map.has_key?(seed_data, "weather_value")

      # Recompute seed from seed_json and verify it matches
      recomputed_seed =
        :crypto.hash(:sha256, completed.seed_json) |> Base.encode16(case: :lower)

      assert completed.seed == recomputed_seed
    end

    test "drand-only fallback when weather is unavailable" do
      # Stub weather to fail
      Req.Test.stub(WeatherClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "down")
      end)

      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      # Simulate attempt 6 (past weather threshold of 5)
      job = %Oban.Job{
        args: %{"draw_id" => draw.id},
        attempt: 6,
        max_attempts: 10
      }

      assert :ok = EntropyWorker.perform(job)

      completed =
        Ash.get!(WallopCore.Resources.Draw, draw.id,
          domain: WallopCore.Domain,
          authorize?: false
        )

      assert completed.status == :completed
      assert completed.seed_source == :entropy
      assert completed.weather_value == nil
      assert completed.weather_fallback_reason != nil

      # seed_json should have only drand and entry_hash (no weather)
      seed_data = Jason.decode!(completed.seed_json)
      assert Map.has_key?(seed_data, "drand_randomness")
      assert Map.has_key?(seed_data, "entry_hash")
      refute Map.has_key?(seed_data, "weather_value")

      # Verify seed uses drand-only computation
      {expected_seed_bytes, expected_seed_json} =
        WallopCore.Protocol.compute_seed(completed.entry_hash, completed.drand_randomness)

      assert completed.seed == Base.encode16(expected_seed_bytes, case: :lower)
      assert completed.seed_json == expected_seed_json

      # Verify results match
      atom_entries = WallopCore.Entries.load_for_draw(completed.id)
      expected_results = FairPick.draw(atom_entries, expected_seed_bytes, completed.winner_count)

      expected_json =
        Enum.map(expected_results, fn %{position: pos, entry_id: id} ->
          %{"position" => pos, "entry_id" => id}
        end)

      assert completed.results == expected_json
    end
  end
end
