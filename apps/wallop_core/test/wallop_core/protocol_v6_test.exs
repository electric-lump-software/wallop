defmodule WallopCore.ProtocolV6Test do
  use ExUnit.Case, async: true
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.DrandClient
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}

  @landobs "drand-quicknet+metoffice-landobs-v1"

  # The fair_pick release this build runs, as the lock and execution paths
  # sign it. Never hard-coded: the verifier accepts only releases it knows.
  @fair_pick Application.spec(:fair_pick, :vsn) |> to_string()

  # drand_round 33_068_212 publishes at 2026-10-14 20:00:00Z, so its
  # observation hour is 19:00:00Z and the latest lock is 18:14:00Z.
  @lock %{
    entropy_composition: @landobs,
    operator_id: "11111111-1111-1111-1111-111111111111",
    operator_slug: "acme-prizes",
    sequence: 7,
    draw_id: "22222222-2222-2222-2222-222222222222",
    commitment_hash: String.duplicate("ab", 32),
    entry_hash: String.duplicate("ab", 32),
    locked_at: ~U[2026-10-14 18:00:00.123456Z],
    signing_key_id: "deadbeef",
    winner_count: 2,
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 33_068_212,
    weather_station: "wmo-03749",
    weather_time: ~U[2026-10-14 19:00:00.000000Z],
    # The round's grid-frequency window start, the tag's fallback window.
    freq_start: ~U[2026-10-14 19:54:00.000000Z],
    wallop_core_version: "0.29.0",
    fair_pick_version: @fair_pick
  }

  # State (a): Middle Wallop's reading, with the lock above's draw.
  @exec WallopCore.TestHelpers.landobs_exec_input()

  # State (c): no reading and no window, so drand alone.
  @fallback %{
    @exec
    | weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: "no_observation_by_deadline",
      freq_fallback_reason: "no_frequency_by_deadline"
  }

  # State (b): no reading, so the round's grid-frequency window.
  @freq_fallback %{
    @fallback
    | freq_value: "50018;50012;49983;49980;49953;49912;49883;49887",
      freq_fallback_reason: nil
  }

  # One entry per accepted entropy tag: {tag module, lock input, exec input}.
  # A second tag adds an entry here, and every field-set test below runs for
  # it against that tag's own expected key lists.
  # The same round under the grid-frequency tag: its window starts at
  # 19:54:00Z and the latest lock is 19:53:00Z.
  @freq_lock %{
    @lock
    | entropy_composition: "drand-quicknet+elexon-freq-v1",
      weather_station: nil,
      weather_time: nil
  }

  @freq_exec %{
    @exec
    | entropy_composition: "drand-quicknet+elexon-freq-v1",
      weather_station: nil,
      weather_observation_time: nil,
      weather_value: nil
  }
  @freq_exec %{
    @freq_exec
    | freq_value: "50018;50012;49983;49980;49953;49912;49883;49887",
      freq_fallback_reason: nil
  }

  @accepted_tags [{LandObs, @lock, @exec}, {Freq, @freq_lock, @freq_exec}]

  test "the accepted tags are exactly the listed tag modules" do
    assert Protocol.v6_entropy_compositions() ==
             Enum.map(@accepted_tags, fn {module, _, _} -> module.tag() end)

    assert Protocol.landobs_entropy_composition() == @landobs
    assert Protocol.landobs_fallback_reason() == "no_observation_by_deadline"
  end

  for {module, lock, exec} <- @accepted_tags do
    @tag_module module
    @tag_lock lock
    @tag_exec exec

    test "#{inspect(module)}: lock v6 has the tag's lock keys, schema 6 and the tag" do
      v6 = Jason.decode!(Protocol.build_v6_lock_payload(@tag_lock))
      assert Map.keys(v6) == Enum.sort(@tag_module.lock_keys())
      assert v6["schema_version"] == "6"
      assert v6["entropy_composition"] == @tag_module.tag()
    end

    test "#{inspect(module)}: exec v5 has the tag's exec keys, schema 5 and the tag" do
      v5 = Jason.decode!(Protocol.build_v6_execution_payload(@tag_exec))
      assert Map.keys(v5) == Enum.sort(@tag_module.exec_keys())
      assert v5["schema_version"] == "5"
      assert v5["entropy_composition"] == @tag_module.tag()
    end
  end

  # The field set lock schemas 2 to 6 and execution schemas 3 to 5 share.
  @base_lock_keys ~w(commitment_hash draw_id drand_chain drand_round entropy_composition
                     entry_hash fair_pick_version jcs_version locked_at operator_id
                     operator_slug schema_version sequence signature_algorithm signing_key_id
                     wallop_core_version weather_station weather_time winner_count)
  @base_exec_keys ~w(draw_id drand_chain drand_randomness drand_round drand_signature
                     drand_signature_algorithm entropy_composition entry_hash executed_at
                     fair_pick_version jcs_version lock_receipt_hash merkle_algorithm operator_id
                     operator_slug results schema_version seed sequence signature_algorithm
                     signing_key_id wallop_core_version weather_fallback_reason
                     weather_observation_time weather_station weather_value)

  test "the landobs lock adds only freq_start to the base lock keys; exec adds only the freq fields" do
    assert LandObs.lock_keys() == Enum.sort(["freq_start" | @base_lock_keys])
    assert length(LandObs.lock_keys()) == 20
    assert LandObs.lock_keys() == Freq.lock_keys()

    assert LandObs.exec_keys() ==
             Enum.sort(["freq_fallback_reason", "freq_value" | @base_exec_keys])

    assert length(LandObs.exec_keys()) == 28
    assert LandObs.exec_keys() == Freq.exec_keys()
  end

  describe "the entropy tag" do
    test "an unknown tag raises on both builders" do
      for tag <- ["drand-quicknet+metoffice-landobs-v2", "drand-quicknet+openmeteo-v1", "", nil] do
        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_v6_lock_payload(%{@lock | entropy_composition: tag})
        end

        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_v6_execution_payload(%{@exec | entropy_composition: tag})
        end
      end
    end

    test "a missing tag raises on both builders" do
      assert_raise ArgumentError, ~r/entropy_composition/, fn ->
        Protocol.build_v6_lock_payload(Map.delete(@lock, :entropy_composition))
      end

      assert_raise ArgumentError, ~r/entropy_composition/, fn ->
        Protocol.build_v6_execution_payload(Map.delete(@exec, :entropy_composition))
      end
    end
  end

  describe "missing and nil inputs" do
    test "lock v6: every input, missing or nil, raises ArgumentError" do
      for key <- Map.keys(@lock) do
        assert_raise ArgumentError, fn ->
          Protocol.build_v6_lock_payload(Map.delete(@lock, key))
        end

        assert_raise ArgumentError, fn ->
          Protocol.build_v6_lock_payload(%{@lock | key => nil})
        end
      end
    end

    test "lock v6: a nil weather_time names the rule" do
      assert_raise ArgumentError, ~r/weather_time/, fn ->
        Protocol.build_v6_lock_payload(%{@lock | weather_time: nil})
      end

      assert_raise ArgumentError, ~r/locked_at must not be nil/, fn ->
        Protocol.build_v6_lock_payload(%{@lock | locked_at: nil})
      end

      assert_raise ArgumentError, ~r/locked_at must be a DateTime/, fn ->
        Protocol.build_v6_lock_payload(%{@lock | locked_at: "2026-10-14T18:00:00.000000Z"})
      end
    end

    test "exec v5: every input, missing or nil, raises ArgumentError" do
      for key <- Map.keys(@exec) do
        assert_raise ArgumentError, fn ->
          Protocol.build_v6_execution_payload(Map.delete(@exec, key))
        end
      end

      # The reasons and freq_value are nil on an observed receipt; nil
      # where its state needs a value is the case to refuse.
      for key <- Map.keys(@exec) -- [:weather_fallback_reason, :freq_value, :freq_fallback_reason] do
        assert_raise ArgumentError, fn ->
          Protocol.build_v6_execution_payload(%{@exec | key => nil})
        end
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_execution_payload(%{@fallback | weather_fallback_reason: nil})
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_execution_payload(%{@fallback | freq_fallback_reason: nil})
      end

      assert_raise ArgumentError, ~r/executed_at must be a DateTime/, fn ->
        Protocol.build_v6_execution_payload(%{@exec | executed_at: "2026-10-14T20:00:06.000000Z"})
      end
    end
  end

  describe "the drand chain" do
    test "the quicknet chain hash is pinned" do
      assert Quicknet.chain_hash() ==
               "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"

      assert Quicknet.chain_hash() == DrandClient.quicknet_chain_hash()
    end

    test "both v6 builders refuse any other chain" do
      # The drand mainnet (default) chain hash.
      other = "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"

      for chain <- [other, String.upcase(@lock.drand_chain), "", nil] do
        assert_raise ArgumentError, ~r/drand_chain/, fn ->
          Protocol.build_v6_lock_payload(%{@lock | drand_chain: chain})
        end

        assert_raise ArgumentError, ~r/drand_chain/, fn ->
          Protocol.build_v6_execution_payload(%{@exec | drand_chain: chain})
        end
      end
    end
  end

  describe "lock v6 under the landobs tag" do
    test "pins the station, the observation hour and the tag" do
      v6 = Jason.decode!(Protocol.build_v6_lock_payload(@lock))
      assert v6["weather_station"] == "wmo-03749"
      assert v6["weather_time"] == "2026-10-14T19:00:00.000000Z"
      assert v6["locked_at"] == "2026-10-14T18:00:00.123456Z"
    end

    test "refuses anything but Middle Wallop and a whole-hour weather_time" do
      assert_raise ArgumentError, fn ->
        Protocol.build_v6_lock_payload(%{@lock | weather_station: "wmo-03462"})
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_lock_payload(%{@lock | weather_time: ~U[2026-10-14 19:00:01.000000Z]})
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_lock_payload(%{@lock | weather_time: ~U[2026-10-14 19:00:00.000001Z]})
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_lock_payload(%{@lock | weather_time: nil})
      end
    end

    test "refuses a weather_time that is not the drand round's observation hour" do
      assert_raise ArgumentError, ~r/observation hour/, fn ->
        Protocol.build_v6_lock_payload(%{@lock | weather_time: ~U[2026-10-14 18:00:00.000000Z]})
      end

      # pub(33_068_212 + 1) is 20:00:03; still 19:00. 20:41:00 is the first
      # round whose observation hour is 20:00.
      assert is_binary(Protocol.build_v6_lock_payload(%{@lock | drand_round: 33_068_213}))

      assert_raise ArgumentError, ~r/observation hour/, fn ->
        Protocol.build_v6_lock_payload(%{@lock | drand_round: 33_068_212 + 41 * 20})
      end
    end

    test "refuses a lock later than weather_time minus 46 minutes, to the microsecond" do
      assert is_binary(
               Protocol.build_v6_lock_payload(%{
                 @lock
                 | locked_at: ~U[2026-10-14 18:14:00.000000Z]
               })
             )

      assert_raise ArgumentError, ~r/46 minutes/, fn ->
        Protocol.build_v6_lock_payload(%{@lock | locked_at: ~U[2026-10-14 18:14:00.000001Z]})
      end
    end
  end

  test "a Land Obs lock signs freq_start, the window start of its round, and refuses any other" do
    input = @lock
    t = FreqSchedule.freq_start_for_round(input.drand_round)
    payload = Protocol.build_v6_lock_payload(Map.put(input, :freq_start, t))
    assert Jason.decode!(payload)["freq_start"] == WallopCore.Time.to_rfc3339_usec(t)

    for bad <- [nil, DateTime.add(t, 15), DateTime.add(t, -15)] do
      assert_raise ArgumentError, ~r/freq_start/, fn ->
        Protocol.build_v6_lock_payload(Map.put(input, :freq_start, bad))
      end
    end

    assert_raise ArgumentError, ~r/freq_start/, fn ->
      Protocol.build_v6_lock_payload(Map.delete(input, :freq_start))
    end
  end

  describe "exec v5 under the landobs tag" do
    test "accepts Middle Wallop's reading and the rule-based fallback, never Wittering" do
      assert is_binary(Protocol.build_v6_execution_payload(@exec))

      assert_raise ArgumentError, ~r/weather_station must be wmo-03749/, fn ->
        Protocol.build_v6_execution_payload(%{@exec | weather_station: "wmo-03462"})
      end

      decoded = Jason.decode!(Protocol.build_v6_execution_payload(@fallback))
      assert decoded["weather_fallback_reason"] == "no_observation_by_deadline"
      assert Map.has_key?(decoded, "weather_value") and decoded["weather_value"] == nil

      assert Map.has_key?(decoded, "weather_observation_time") and
               decoded["weather_observation_time"] == nil

      assert decoded["freq_fallback_reason"] == "no_frequency_by_deadline"
      assert Map.has_key?(decoded, "freq_value") and decoded["freq_value"] == nil

      decoded = Jason.decode!(Protocol.build_v6_execution_payload(@freq_fallback))
      assert decoded["weather_fallback_reason"] == "no_observation_by_deadline"
      assert decoded["freq_value"] == @freq_fallback.freq_value

      assert Map.has_key?(decoded, "freq_fallback_reason") and
               decoded["freq_fallback_reason"] == nil
    end

    test "refuses partial fallbacks, v5 reasons, foreign stations and off-grammar values" do
      bad = [
        %{@exec | weather_station: "middle-wallop"},
        %{@exec | weather_station: nil},
        %{@fallback | weather_fallback_reason: "unreachable"},
        %{@fallback | weather_fallback_reason: nil},
        %{@fallback | freq_fallback_reason: nil},
        %{@fallback | freq_fallback_reason: "unreachable"},
        %{@exec | freq_value: @freq_fallback.freq_value},
        %{@exec | freq_fallback_reason: "no_frequency_by_deadline"},
        %{@freq_fallback | freq_value: "50018;50012"},
        %{@freq_fallback | freq_fallback_reason: "no_frequency_by_deadline"},
        %{@freq_fallback | weather_fallback_reason: nil},
        %{@exec | weather_value: nil},
        %{@exec | weather_observation_time: nil},
        %{@exec | weather_fallback_reason: "no_observation_by_deadline"},
        %{@exec | weather_value: "102500"},
        %{@exec | weather_observation_time: ~U[2026-10-14 19:10:00.000000Z]},
        %{@exec | weather_observation_time: ~U[2026-10-14 19:00:00.000001Z]}
      ]

      for input <- bad do
        assert_raise ArgumentError, fn -> Protocol.build_v6_execution_payload(input) end
      end
    end

    test "refuses an observation hour other than the drand round's" do
      assert_raise ArgumentError, ~r/observation hour/, fn ->
        Protocol.build_v6_execution_payload(%{
          @exec
          | weather_observation_time: ~U[2026-10-14 18:00:00.000000Z]
        })
      end
    end

    test "refuses an executed_at before the drand round was published" do
      assert is_binary(
               Protocol.build_v6_execution_payload(%{
                 @exec
                 | executed_at: ~U[2026-10-14 20:00:00.000000Z]
               })
             )

      assert_raise ArgumentError, ~r/published/, fn ->
        Protocol.build_v6_execution_payload(%{
          @exec
          | executed_at: ~U[2026-10-14 19:59:59.999999Z]
        })
      end
    end

    test "a fallback names Middle Wallop, never Wittering" do
      assert Jason.decode!(Protocol.build_v6_execution_payload(@fallback))["weather_station"] ==
               "wmo-03749"

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_execution_payload(%{@fallback | weather_station: "wmo-03462"})
      end
    end

    test "refuses values outside the frozen bounds" do
      for bad <- ["601;1025;85;2432", "141;849;85;2432", "141;1025;101;2432", "141;1025;85;10001"] do
        assert_raise ArgumentError, fn ->
          Protocol.build_v6_execution_payload(%{@exec | weather_value: bad})
        end
      end
    end
  end

  describe "the fair_pick release" do
    test "the running fair_pick is the pinned 0.2.0" do
      assert @fair_pick == "0.2.0",
             "fair_pick is #{@fair_pick}, not 0.2.0. Every lock v6 / execution v5 receipt " <>
               "signs this version and the verifier accepts only releases it knows: add it " <>
               "to wallop_rs FAIR_PICK_VERSIONS in the same release, then update this pin."
    end
  end

  describe "byte-level output" do
    # Exact JCS bytes. Any change here changes every signature under the tag.
    test "lock v6 bytes" do
      assert Protocol.build_v6_lock_payload(@lock) ==
               ~s({"commitment_hash":"#{String.duplicate("ab", 32)}",) <>
                 ~s("drand_chain":"52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",) <>
                 ~s("drand_round":33068212,) <>
                 ~s("draw_id":"22222222-2222-2222-2222-222222222222",) <>
                 ~s("entropy_composition":"drand-quicknet+metoffice-landobs-v1",) <>
                 ~s("entry_hash":"#{String.duplicate("ab", 32)}",) <>
                 ~s("fair_pick_version":"0.2.0",) <>
                 ~s("freq_start":"2026-10-14T19:54:00.000000Z","jcs_version":"sha256-jcs-v1",) <>
                 ~s("locked_at":"2026-10-14T18:00:00.123456Z",) <>
                 ~s("operator_id":"11111111-1111-1111-1111-111111111111",) <>
                 ~s("operator_slug":"acme-prizes","schema_version":"6","sequence":7,) <>
                 ~s("signature_algorithm":"ed25519","signing_key_id":"deadbeef",) <>
                 ~s("wallop_core_version":"0.29.0","weather_station":"wmo-03749",) <>
                 ~s("weather_time":"2026-10-14T19:00:00.000000Z","winner_count":2})
    end

    test "payload SHA-256 is pinned" do
      sha = &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))

      assert sha.(Protocol.build_v6_lock_payload(@lock)) ==
               "16d671bd16da0f6c4ef6bf9343b0aaacb9e43f0284614ac23a2093cf24826c78"

      assert sha.(Protocol.build_v6_execution_payload(@exec)) ==
               "2a402cece4c76615cc5157c80f9010c84a3ab1c4d728deebde06a2afe9cf0383"

      assert sha.(Protocol.build_v6_execution_payload(@fallback)) ==
               "95dc7aeae249abdf0f5d230d60ce43b6d5b38cbb65ad792ee06745d4918f772a"

      assert sha.(Protocol.build_v6_execution_payload(@freq_fallback)) ==
               "2368d111cdabf74b91bfee9a1239d9ec71cef722b82b330ef7ab4b8699c7e9d6"
    end

    test "exec v5 fallback bytes carry explicit nulls" do
      payload = Protocol.build_v6_execution_payload(@fallback)

      assert payload =~
               ~s("weather_fallback_reason":"no_observation_by_deadline",) <>
                 ~s("weather_observation_time":null,"weather_station":"wmo-03749",) <>
                 ~s("weather_value":null})

      assert payload =~
               ~s("freq_fallback_reason":"no_frequency_by_deadline","freq_value":null,)

      assert payload =~ ~s("schema_version":"5")
    end
  end
end
