defmodule WallopCore.Entropy.V6RulesTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.V6Rules
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Weather.Stations

  @landobs LandObs.tag()
  @unknown "drand-quicknet+metoffice-landobs-v2"

  defp pair(schema, tag), do: %{lock_schema_version: schema, entropy_composition: tag}

  test "only (6, Land Obs) has rules" do
    assert V6Rules.rules(pair("6", @landobs)) == {:ok, :landobs}
    assert V6Rules.rules!(pair("6", @landobs)) == :landobs

    for {schema, tag} <- [{nil, @landobs}, {"5", @landobs}, {"6", nil}, {"6", @unknown}] do
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

  test "a fallback's receipt input names the first station and carries the draw's tag" do
    draw = %{
      entropy_composition: @landobs,
      weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: Protocol.landobs_fallback_reason()
    }

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

  test "seeds: with the reading, or drand alone" do
    hash = String.duplicate("ab", 32)
    r = String.duplicate("c", 64)
    assert V6Rules.seed(:landobs, hash, r, nil) == Protocol.compute_seed(hash, r)

    assert V6Rules.seed(:landobs, hash, r, %{value: "1;1000;1;1"}) ==
             Protocol.compute_seed(hash, r, "1;1000;1;1")
  end
end
