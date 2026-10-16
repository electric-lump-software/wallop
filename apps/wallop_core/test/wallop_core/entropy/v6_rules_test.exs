defmodule WallopCore.Entropy.V6RulesTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.V6Rules
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Weather.Stations

  @landobs LandObs.tag()
  @unknown "drand-quicknet+metoffice-landobs-v2"

  defp pair(schema, tag), do: %{lock_schema_version: schema, entropy_composition: tag}

  test "only (6, Land Obs) and (6, grid frequency) have rules" do
    assert V6Rules.rules(pair("6", @landobs)) == {:ok, :landobs}
    assert V6Rules.rules!(pair("6", @landobs)) == :landobs
    assert V6Rules.rules(pair("6", Freq.tag())) == {:ok, :freq}
    assert V6Rules.rules!(pair("6", Freq.tag())) == :freq

    refused = [
      {nil, @landobs},
      {"5", @landobs},
      {"6", nil},
      {"6", @unknown},
      {"6", "drand-quicknet+elexon-freq-v2"},
      {"5", Freq.tag()},
      {nil, Freq.tag()}
    ]

    for {schema, tag} <- refused do
      assert V6Rules.rules(pair(schema, tag)) == :error, inspect({schema, tag})

      message = V6Rules.unknown_pair_message(schema, tag)

      assert_raise ArgumentError, message, fn -> V6Rules.rules!(pair(schema, tag)) end
    end
  end

  test "the unknown-pair message matches the draws guard's, NULL as <NULL>" do
    assert V6Rules.unknown_pair_message("6", nil) ==
             "unknown lock_schema_version and entropy_composition pair: (6, <NULL>)"

    assert V6Rules.unknown_pair_message(nil, @landobs) ==
             "unknown lock_schema_version and entropy_composition pair: (<NULL>, #{@landobs})"
  end

  test "completion attributes: the reading, or the fallback by rule" do
    wt = ~U[2026-10-15 12:00:00.000000Z]
    reading = %{station: "wmo-03462", value: "141;1025;85;2432", raw: "[]", observation_time: wt}

    assert V6Rules.completion_attrs(:landobs, reading) == %{
             weather_value: "141;1025;85;2432",
             weather_raw: "[]",
             weather_observation_time: wt,
             weather_fallback_reason: nil
           }

    assert V6Rules.completion_attrs(:landobs, nil) == %{
             weather_value: nil,
             weather_raw: nil,
             weather_observation_time: nil,
             weather_fallback_reason: Protocol.landobs_fallback_reason()
           }
  end

  # A completed Land Obs fallback draw as the signer sees it.
  defp landobs_fallback(overrides \\ %{}) do
    hash = String.duplicate("ab", 32)
    r = String.duplicate("c", 64)
    {seed, _} = Protocol.compute_seed(hash, r)

    Map.merge(
      %{
        entropy_composition: @landobs,
        entry_hash: hash,
        drand_randomness: r,
        seed: Base.encode16(seed, case: :lower),
        weather_value: nil,
        weather_observation_time: nil,
        weather_fallback_reason: Protocol.landobs_fallback_reason()
      },
      overrides
    )
  end

  test "a fallback's receipt input names the first station and carries the draw's tag" do
    draw = landobs_fallback()

    assert V6Rules.receipt_input(:landobs, draw) ==
             {:ok,
              %{
                entropy_composition: @landobs,
                weather_station: Stations.primary().id,
                weather_value: nil,
                weather_observation_time: nil,
                weather_fallback_reason: Protocol.landobs_fallback_reason()
              }}
  end

  test "the signer recomputes a Land Obs fallback's seed: any other seed is refused" do
    hash = String.duplicate("ab", 32)
    r = String.duplicate("c", 64)

    for {bytes, _} <- [
          Protocol.compute_seed(hash, r, "141;1025;85;2432"),
          Protocol.compute_freq_seed(hash, r, "141;1025;85;2432"),
          {String.duplicate(<<0>>, 32), ""}
        ] do
      seed = Base.encode16(bytes, case: :lower)

      assert V6Rules.receipt_input(:landobs, landobs_fallback(%{seed: seed})) ==
               {:error, "the draw's seed is not the Land Observations seed of its inputs"}
    end

    assert {:error, _} = V6Rules.receipt_input(:landobs, landobs_fallback(%{seed: nil}))
  end

  test "rules!/1 raises ArgumentError for a map without the pair keys" do
    assert_raise ArgumentError, V6Rules.unknown_pair_message(nil, nil), fn ->
      V6Rules.rules!(%{})
    end
  end

  test "seeds: with the reading, or drand alone" do
    hash = String.duplicate("ab", 32)
    r = String.duplicate("c", 64)
    assert V6Rules.seed(:landobs, hash, r, nil) == Protocol.compute_seed(hash, r)

    assert V6Rules.seed(:landobs, hash, r, %{value: "1;1000;1;1"}) ==
             Protocol.compute_seed(hash, r, "1;1000;1;1")
  end

  describe "the grid-frequency rules" do
    @freq_value "50018;50012;49983;49980;49953;49912;49883;49887"
    @hash String.duplicate("ab", 32)
    @randomness String.duplicate("c", 64)

    defp hex({bytes, _json}), do: Base.encode16(bytes, case: :lower)

    # A completed fallback draw as the signer sees it.
    defp freq_fallback(overrides \\ %{}) do
      Map.merge(
        %{
          entropy_composition: Freq.tag(),
          entry_hash: @hash,
          drand_randomness: @randomness,
          seed: hex(Protocol.compute_seed(@hash, @randomness)),
          freq_value: nil,
          freq_fallback_reason: Freq.fallback_reason()
        },
        overrides
      )
    end

    test "timing comes from freq_start and the round" do
      t = ~U[2026-10-14 19:54:00.000000Z]
      draw = %{freq_start: t, drand_round: 33_068_212}
      assert V6Rules.fetch_deadline(:freq, draw) == ~U[2026-10-14 19:59:45.000000Z]
      assert V6Rules.drand_pub_time(:freq, draw) == ~U[2026-10-14 20:00:00.000000Z]
    end

    test "seeds: the frequency seed with a window, drand alone without" do
      assert V6Rules.seed(:freq, @hash, @randomness, nil) ==
               Protocol.compute_seed(@hash, @randomness)

      assert V6Rules.seed(:freq, @hash, @randomness, %{value: @freq_value}) ==
               Protocol.compute_freq_seed(@hash, @randomness, @freq_value)

      refute V6Rules.seed(:freq, @hash, @randomness, %{value: @freq_value}) ==
               Protocol.compute_seed(@hash, @randomness, @freq_value)
    end

    test "completion attributes set only the frequency fields" do
      reading = %{value: @freq_value, raw: "{}", freq_start: ~U[2026-10-14 19:54:00.000000Z]}

      assert V6Rules.completion_attrs(:freq, reading) ==
               %{freq_value: @freq_value, freq_fallback_reason: nil}

      assert V6Rules.completion_attrs(:freq, nil) ==
               %{freq_value: nil, freq_fallback_reason: Freq.fallback_reason()}
    end

    test "a fallback's receipt input: the tag, no weather, the reason" do
      assert V6Rules.receipt_input(:freq, freq_fallback()) ==
               {:ok,
                %{
                  entropy_composition: Freq.tag(),
                  weather_station: nil,
                  weather_value: nil,
                  weather_observation_time: nil,
                  weather_fallback_reason: nil,
                  freq_value: nil,
                  freq_fallback_reason: Freq.fallback_reason()
                }}
    end

    test "the signer recomputes the seed: any other seed is refused" do
      for seed <- [
            hex(Protocol.compute_freq_seed(@hash, @randomness, @freq_value)),
            hex(Protocol.compute_seed(@hash, @randomness, @freq_value)),
            String.duplicate("0", 64),
            nil
          ] do
        assert V6Rules.receipt_input(:freq, freq_fallback(%{seed: seed})) ==
                 {:error, "the draw's seed is not the grid-frequency seed of its inputs"},
               inspect(seed)
      end
    end

    test "fallback reason and station: the tag's reason, no station" do
      assert V6Rules.fallback_reason(:freq) == Freq.fallback_reason()
      assert V6Rules.fallback_station(:freq) == nil
    end

    test "report metadata names the tag and whether it fell back" do
      assert V6Rules.report_meta(:freq, %{entropy_composition: Freq.tag(), freq_value: nil}) ==
               %{entropy_composition: Freq.tag(), station: nil, fallback?: true}

      assert V6Rules.report_meta(:freq, %{
               entropy_composition: Freq.tag(),
               freq_value: @freq_value
             }) ==
               %{entropy_composition: Freq.tag(), station: nil, fallback?: false}
    end
  end
end
