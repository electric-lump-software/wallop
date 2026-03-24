defmodule WallopCore.ProtocolTest do
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  describe "entry_hash/1" do
    test "matches spec vector P-1" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      expected_jcs =
        ~s({"entries":[{"id":"ticket-47","weight":1},{"id":"ticket-48","weight":1},{"id":"ticket-49","weight":1}]})

      {hash, jcs} = Protocol.entry_hash(entries)

      assert jcs == expected_jcs
      assert hash == hex_sha256(expected_jcs)
      assert String.match?(hash, ~r/^[0-9a-f]{64}$/)
    end

    test "sorts entries by id regardless of input order" do
      entries_a = [%{id: "b", weight: 1}, %{id: "a", weight: 1}]
      entries_b = [%{id: "a", weight: 1}, %{id: "b", weight: 1}]
      assert Protocol.entry_hash(entries_a) == Protocol.entry_hash(entries_b)
    end
  end

  describe "compute_seed/3" do
    test "matches spec vector P-2" do
      drand_randomness = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      entry_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      weather_value = "1013"

      expected_json =
        ~s({"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","weather_value":"1013"})

      {seed_bytes, seed_json} =
        Protocol.compute_seed(entry_hash, drand_randomness, weather_value)

      assert seed_json == expected_json
      assert byte_size(seed_bytes) == 32
      assert seed_bytes == :crypto.hash(:sha256, expected_json)
    end

    test "JCS sorts keys alphabetically regardless of input key order" do
      # The arguments are (entry_hash, drand_randomness, weather_value).
      # In the JSON, "drand_randomness" < "entry_hash" < "weather_value" alphabetically.
      # Verify the output JSON has keys in that order, not argument order.
      {_seed, json} = Protocol.compute_seed("zzz_entry", "aaa_drand", "mmm_weather")

      assert json ==
               ~s({"drand_randomness":"aaa_drand","entry_hash":"zzz_entry","weather_value":"mmm_weather"})
    end
  end

  describe "protocol vectors (spec §3.2)" do
    test "P-1: entry hash" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      {hash, _jcs} = Protocol.entry_hash(entries)

      assert hash == "6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577"
    end

    test "P-2: seed" do
      drand = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      entry_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      weather = "1013"

      {seed_bytes, _json} = Protocol.compute_seed(entry_hash, drand, weather)

      assert Base.encode16(seed_bytes, case: :lower) ==
               "4c1ae3e623dd22859d869f4d0cb34d3acaf4cf7907dbb472ea690e1400bfb0d0"
    end

    test "P-3: end-to-end" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      drand = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      weather = "1013"

      {entry_hash, _jcs} = Protocol.entry_hash(entries)
      {seed_bytes, _json} = Protocol.compute_seed(entry_hash, drand, weather)
      result = FairPick.draw(entries, seed_bytes, 2)

      assert entry_hash == "6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577"

      assert Base.encode16(seed_bytes, case: :lower) ==
               "ced93f50d73a619701e9e865eb03fb4540a7232a588c707f85754aa41e3fb037"

      assert result == [
               %{position: 1, entry_id: "ticket-48"},
               %{position: 2, entry_id: "ticket-47"}
             ]
    end
  end

  defp hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
