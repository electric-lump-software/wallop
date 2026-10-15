defmodule WallopCore.ProtocolV6Test do
  use ExUnit.Case, async: true
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.DrandClient
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs

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
    wallop_core_version: "0.29.0",
    fair_pick_version: @fair_pick
  }

  @exec %{
    entropy_composition: @landobs,
    draw_id: @lock.draw_id,
    operator_id: @lock.operator_id,
    operator_slug: "acme-prizes",
    sequence: 7,
    lock_receipt_hash: String.duplicate("cd", 32),
    entry_hash: @lock.entry_hash,
    drand_chain: @lock.drand_chain,
    drand_round: 33_068_212,
    drand_randomness: "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd",
    drand_signature:
      "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf",
    weather_station: "wmo-03749",
    weather_observation_time: ~U[2026-10-14 19:00:00.000000Z],
    weather_value: "141;1025;85;2432",
    weather_fallback_reason: nil,
    wallop_core_version: "0.29.0",
    fair_pick_version: @fair_pick,
    seed: String.duplicate("ef", 32),
    results: ["33333333-3333-3333-3333-333333333333"],
    executed_at: ~U[2026-10-14 20:00:06.000000Z],
    signing_key_id: "cafebabe"
  }

  @fallback %{
    @exec
    | weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: "no_observation_by_deadline"
  }

  # One entry per accepted entropy tag: {tag module, lock input, exec input}.
  # A second tag adds an entry here, and every field-set test below runs for
  # it against that tag's own expected key lists.
  @accepted_tags [{LandObs, @lock, @exec}]

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

  test "the landobs tag adds no fields: its key lists are the lock 5 / exec 4 key sets" do
    lock_v5 = Jason.decode!(Protocol.build_receipt_payload(v5_input(@lock)))
    exec_v4 = Jason.decode!(Protocol.build_execution_receipt_payload(v5_input(@exec)))

    assert LandObs.lock_keys() == Map.keys(lock_v5)
    assert LandObs.exec_keys() == Map.keys(exec_v4)
  end

  # The same input, as the lock 5 / execution 4 builders take it: no tag,
  # the old station and an old-style value.
  defp v5_input(input) do
    input
    |> Map.delete(:entropy_composition)
    |> Map.put(:weather_station, "middle-wallop")
    |> old_style_value()
  end

  defp old_style_value(%{weather_value: value} = input) when is_binary(value),
    do: %{input | weather_value: "102500"}

  defp old_style_value(input), do: input

  describe "the lock 5 / execution 4 builders and the tag" do
    test "no tag or the openmeteo tag keeps today's bytes" do
      openmeteo = Protocol.entropy_composition()

      for input <- [v5_input(@lock), Map.put(v5_input(@lock), :entropy_composition, openmeteo)] do
        assert Protocol.build_receipt_payload(input) ==
                 Protocol.build_receipt_payload(v5_input(@lock))
      end

      for input <- [v5_input(@exec), Map.put(v5_input(@exec), :entropy_composition, openmeteo)] do
        assert Protocol.build_execution_receipt_payload(input) ==
                 Protocol.build_execution_receipt_payload(v5_input(@exec))
      end

      decoded = Jason.decode!(Protocol.build_receipt_payload(v5_input(@lock)))
      assert decoded["entropy_composition"] == "drand-quicknet+openmeteo-v1"
      assert decoded["schema_version"] == "5"
    end

    test "any other tag is refused" do
      for tag <- [@landobs, "drand-quicknet+metoffice-landobs-v2", "", nil] do
        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_receipt_payload(Map.put(v5_input(@lock), :entropy_composition, tag))
        end

        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_execution_receipt_payload(
            Map.put(v5_input(@exec), :entropy_composition, tag)
          )
        end
      end
    end
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

      # weather_fallback_reason is nil on an observed receipt; nil on a
      # fallback is the case to refuse.
      for key <- Map.keys(@exec) -- [:weather_fallback_reason] do
        assert_raise ArgumentError, fn ->
          Protocol.build_v6_execution_payload(%{@exec | key => nil})
        end
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_execution_payload(%{@fallback | weather_fallback_reason: nil})
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

    test "refuses anything but the first station and a whole-hour weather_time" do
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

  describe "exec v5 under the landobs tag" do
    test "accepts the backup station and the rule-based fallback" do
      assert is_binary(
               Protocol.build_v6_execution_payload(%{@exec | weather_station: "wmo-03462"})
             )

      decoded = Jason.decode!(Protocol.build_v6_execution_payload(@fallback))
      assert decoded["weather_fallback_reason"] == "no_observation_by_deadline"
      assert Map.has_key?(decoded, "weather_value") and decoded["weather_value"] == nil

      assert Map.has_key?(decoded, "weather_observation_time") and
               decoded["weather_observation_time"] == nil
    end

    test "refuses partial fallbacks, v5 reasons, foreign stations and off-grammar values" do
      bad = [
        %{@exec | weather_station: "middle-wallop"},
        %{@exec | weather_station: nil},
        %{@fallback | weather_fallback_reason: "unreachable"},
        %{@fallback | weather_fallback_reason: nil},
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

    test "v5 builders still refuse the landobs-only fallback reason" do
      assert_raise ArgumentError, fn ->
        Protocol.build_execution_receipt_payload(v5_input(@fallback))
      end
    end

    test "a fallback names the primary station, never the backup" do
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
                 ~s("fair_pick_version":"0.2.0","jcs_version":"sha256-jcs-v1",) <>
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
               "b8b0943389d5d3e6c455bbc7b812b6ebd6bde35619d59f1fc4b2014a48dba616"

      assert sha.(Protocol.build_v6_execution_payload(@exec)) ==
               "eda3da304ced89945e31865dcca54f111c9ed7c0a112f3e889a0e5db88d27317"

      assert sha.(Protocol.build_v6_execution_payload(@fallback)) ==
               "06a9dbbc0adedc7557894c3e31d4d0ad34492fb9e2e8c79b4df863ab54a2f2b2"
    end

    test "exec v5 fallback bytes carry explicit nulls" do
      payload = Protocol.build_v6_execution_payload(@fallback)

      assert payload =~
               ~s("weather_fallback_reason":"no_observation_by_deadline",) <>
                 ~s("weather_observation_time":null,"weather_station":"wmo-03749",) <>
                 ~s("weather_value":null})

      assert payload =~ ~s("schema_version":"5")
    end
  end
end
