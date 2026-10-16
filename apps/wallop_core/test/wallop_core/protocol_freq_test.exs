defmodule WallopCore.ProtocolFreqTest do
  use ExUnit.Case, async: true
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.Freq

  @freq "drand-quicknet+elexon-freq-v1"

  # The fair_pick release this build runs, as the lock and execution paths
  # sign it. Never hard-coded: the verifier accepts only releases it knows.
  @fair_pick Application.spec(:fair_pick, :vsn) |> to_string()
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @value "50018;50012;49983;49980;49953;49912;49883;49887"

  # drand_round 33_068_212 publishes at 2026-10-14 20:00:00Z, so (W_freq = 240 s,
  # M = 15 s) its window starts at 19:54:00Z and the latest lock is 19:53:00Z.
  @lock %{
    entropy_composition: @freq,
    operator_id: "11111111-1111-1111-1111-111111111111",
    operator_slug: "acme-prizes",
    sequence: 7,
    draw_id: "22222222-2222-2222-2222-222222222222",
    commitment_hash: String.duplicate("ab", 32),
    entry_hash: String.duplicate("ab", 32),
    locked_at: ~U[2026-10-14 19:50:00.123456Z],
    signing_key_id: "deadbeef",
    winner_count: 2,
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 33_068_212,
    weather_station: nil,
    weather_time: nil,
    freq_start: ~U[2026-10-14 19:54:00.000000Z],
    wallop_core_version: "0.29.0",
    fair_pick_version: @fair_pick
  }

  @exec %{
    entropy_composition: @freq,
    draw_id: @lock.draw_id,
    operator_id: @lock.operator_id,
    operator_slug: "acme-prizes",
    sequence: 7,
    lock_receipt_hash: String.duplicate("cd", 32),
    entry_hash: @lock.entry_hash,
    drand_chain: @lock.drand_chain,
    drand_round: 33_068_212,
    drand_randomness: @randomness,
    drand_signature:
      "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf",
    weather_station: nil,
    weather_observation_time: nil,
    weather_value: nil,
    weather_fallback_reason: nil,
    freq_value: @value,
    freq_fallback_reason: nil,
    wallop_core_version: "0.29.0",
    fair_pick_version: @fair_pick,
    seed: String.duplicate("ef", 32),
    results: ["33333333-3333-3333-3333-333333333333"],
    executed_at: ~U[2026-10-14 20:00:05.000000Z],
    signing_key_id: "cafebabe"
  }

  @fallback %{@exec | freq_value: nil, freq_fallback_reason: "no_frequency_by_deadline"}

  test "both tags are accepted for lock v6 / exec v5" do
    assert Protocol.freq_entropy_composition() == @freq
    assert Protocol.freq_fallback_reason() == "no_frequency_by_deadline"
    assert @freq in Protocol.v6_entropy_compositions()
    assert Protocol.landobs_entropy_composition() in Protocol.v6_entropy_compositions()
  end

  test "lock v6 under the frequency tag: 20 fields, freq_start signed, weather fields null" do
    payload = @lock |> Protocol.build_v6_lock_payload() |> Jason.decode!()
    assert Enum.sort(Map.keys(payload)) == Freq.lock_keys()
    assert Freq.lock_keys() == Enum.sort(Freq.lock_keys())
    assert map_size(payload) == 20
    assert payload["schema_version"] == "6"
    assert payload["entropy_composition"] == @freq
    assert payload["freq_start"] == "2026-10-14T19:54:00.000000Z"
    assert payload["weather_station"] == nil
    assert payload["weather_time"] == nil
  end

  test "lock v6 refuses weather fields, an underived freq_start and a late locked_at" do
    for bad <- [
          %{@lock | weather_station: "wmo-03749"},
          %{@lock | weather_time: ~U[2026-10-14 19:00:00.000000Z]},
          %{@lock | freq_start: ~U[2026-10-14 19:53:45.000000Z]},
          %{@lock | freq_start: nil},
          Map.delete(@lock, :freq_start),
          %{@lock | locked_at: ~U[2026-10-14 19:53:00.000001Z]}
        ] do
      assert_raise ArgumentError, fn -> Protocol.build_v6_lock_payload(bad) end
    end

    assert Protocol.build_v6_lock_payload(%{@lock | locked_at: ~U[2026-10-14 19:53:00.000000Z]})
  end

  test "exec v5 under the frequency tag: 28 fields; value or fallback, never both" do
    payload = @exec |> Protocol.build_v6_execution_payload() |> Jason.decode!()
    assert Enum.sort(Map.keys(payload)) == Freq.exec_keys()
    assert Freq.exec_keys() == Enum.sort(Freq.exec_keys())
    assert map_size(payload) == 28
    assert payload["schema_version"] == "5"
    assert payload["freq_value"] == @value
    assert payload["freq_fallback_reason"] == nil

    assert Enum.all?(
             ~w(weather_station weather_value weather_observation_time weather_fallback_reason),
             &is_nil(payload[&1])
           )

    fallback = @fallback |> Protocol.build_v6_execution_payload() |> Jason.decode!()
    assert fallback["freq_value"] == nil
    assert fallback["freq_fallback_reason"] == "no_frequency_by_deadline"
  end

  test "exec v5 refuses weather fields, the weather reason, partial fallbacks, bad values and early execution" do
    for bad <- [
          %{@exec | weather_station: "wmo-03749"},
          %{@exec | weather_value: "141;1025;85;2432"},
          %{@fallback | freq_fallback_reason: "no_observation_by_deadline"},
          %{
            @fallback
            | weather_fallback_reason: "no_frequency_by_deadline",
              freq_fallback_reason: nil
          },
          %{@exec | freq_fallback_reason: "no_frequency_by_deadline"},
          %{@exec | freq_value: nil},
          %{@exec | freq_value: "50000;50000;50000;50000;50000;50000;50012;50013"},
          %{@exec | freq_value: "53000;50012;49983;49980;49953;49912;49883;49887"},
          %{@exec | executed_at: ~U[2026-10-14 19:59:59.999999Z]}
        ] do
      assert_raise ArgumentError, fn -> Protocol.build_v6_execution_payload(bad) end
    end
  end

  test "the Land Observations tag never signs a frequency field" do
    landobs = %{@lock | entropy_composition: Protocol.landobs_entropy_composition()}

    refute Map.has_key?(
             Jason.decode!(
               Protocol.build_v6_lock_payload(
                 Map.merge(landobs, %{
                   weather_station: "wmo-03749",
                   weather_time: ~U[2026-10-14 19:00:00.000000Z],
                   locked_at: ~U[2026-10-14 18:00:00.000000Z]
                 })
               )
             ),
             "freq_start"
           )
  end

  test "lock v6 bytes under the frequency tag, written out by hand" do
    assert Protocol.build_v6_lock_payload(@lock) ==
             ~s({"commitment_hash":"#{String.duplicate("ab", 32)}",) <>
               ~s("drand_chain":"52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",) <>
               ~s("drand_round":33068212,"draw_id":"22222222-2222-2222-2222-222222222222",) <>
               ~s("entropy_composition":"drand-quicknet+elexon-freq-v1",) <>
               ~s("entry_hash":"#{String.duplicate("ab", 32)}",) <>
               ~s("fair_pick_version":"#{@fair_pick}",) <>
               ~s("freq_start":"2026-10-14T19:54:00.000000Z","jcs_version":"sha256-jcs-v1",) <>
               ~s("locked_at":"2026-10-14T19:50:00.123456Z",) <>
               ~s("operator_id":"11111111-1111-1111-1111-111111111111",) <>
               ~s("operator_slug":"acme-prizes","schema_version":"6","sequence":7,) <>
               ~s("signature_algorithm":"ed25519","signing_key_id":"deadbeef",) <>
               ~s("wallop_core_version":"0.29.0","weather_station":null,"weather_time":null,) <>
               ~s("winner_count":2})
  end

  test "exec v5 fallback bytes under the frequency tag carry explicit nulls" do
    payload = Protocol.build_v6_execution_payload(@fallback)

    assert payload =~
             ~s("freq_fallback_reason":"no_frequency_by_deadline","freq_value":null,)

    assert payload =~
             ~s("weather_fallback_reason":null,"weather_observation_time":null,) <>
               ~s("weather_station":null,"weather_value":null})
  end

  test "frequency inputs never change Land Observations bytes" do
    landobs_lock = %{
      @lock
      | entropy_composition: Protocol.landobs_entropy_composition(),
        weather_station: "wmo-03749",
        weather_time: ~U[2026-10-14 19:00:00.000000Z],
        locked_at: ~U[2026-10-14 18:00:00.123456Z]
    }

    landobs_exec = %{
      @exec
      | entropy_composition: Protocol.landobs_entropy_composition(),
        weather_station: "wmo-03749",
        weather_observation_time: ~U[2026-10-14 19:00:00.000000Z],
        weather_value: "141;1025;85;2432"
    }

    assert Protocol.build_v6_lock_payload(landobs_lock) ==
             Protocol.build_v6_lock_payload(Map.delete(landobs_lock, :freq_start))

    bare_exec = Map.drop(landobs_exec, [:freq_value, :freq_fallback_reason])

    assert Protocol.build_v6_execution_payload(landobs_exec) ==
             Protocol.build_v6_execution_payload(bare_exec)

    refute Protocol.build_v6_execution_payload(landobs_exec) =~ "freq_"
  end

  test "an unknown tag still raises" do
    assert_raise ArgumentError, fn ->
      Protocol.build_v6_lock_payload(%{
        @lock
        | entropy_composition: "drand-quicknet+elexon-freq-v2"
      })
    end
  end

  test "the frequency seed: SHA256(JCS{drand_randomness, entry_hash, freq_value}), distinct from the weather seed" do
    entry_hash = String.duplicate("ab", 32)
    {bytes, jcs} = Protocol.compute_freq_seed(entry_hash, @randomness, @value)

    assert jcs ==
             ~s({"drand_randomness":"#{@randomness}","entry_hash":"#{entry_hash}","freq_value":"#{@value}"})

    assert Base.encode16(bytes, case: :lower) ==
             "ab4a8f4bba2b29e391e185625a5b963d026c9f8d3f84bd116aeeae31e864b295"

    {weather_bytes, _} = Protocol.compute_seed(entry_hash, @randomness, @value)

    assert Base.encode16(weather_bytes, case: :lower) ==
             "bbf11c2b9ca4ae686dc8462888335ac9828e5c9895a4c531f8972a2f9797e174"
  end
end
