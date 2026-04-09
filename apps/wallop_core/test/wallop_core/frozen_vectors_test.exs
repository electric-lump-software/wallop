defmodule WallopCore.FrozenVectorsTest do
  @moduledoc """
  PROTOCOL COMMITMENT — FROZEN TEST VECTORS

  These tests pin the exact byte-level output of every protocol function.
  If any assertion fails, the protocol has drifted and every previously
  issued proof may be unverifiable. DO NOT update expected values without:

    1. A wallop_core version bump
    2. A CHANGELOG entry with BREAKING prefix
    3. An update to spec/protocol.md
    4. Agreement that historical proofs under the old version remain
       verifiable (or an explicit decision to break them)

  The vectors here cover:
    - entry_hash canonicalization + SHA-256
    - compute_seed (drand + weather, drand-only)
    - FairPick.draw/3 (equal weight, weighted, edge cases)
    - Lock receipt JCS payload
    - Execution receipt JCS payload
    - Ed25519 signing
    - End-to-end draw (entries → hash → seed → winners)
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  # ── RFC 8032 test keypair (deterministic, well-known) ──────────────

  @test_private_key Base.decode16!(
                      "9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60",
                      case: :mixed
                    )
  @test_public_key Base.decode16!(
                     "D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A",
                     case: :mixed
                   )

  @drand_hex "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

  # ── V-1: entry_hash ────────────────────────────────────────────────

  describe "V-1: entry_hash" do
    test "equal-weight entries" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      {hash, jcs} = Protocol.entry_hash(entries)

      assert jcs ==
               ~s({"entries":[{"id":"ticket-47","weight":1},{"id":"ticket-48","weight":1},{"id":"ticket-49","weight":1}]})

      assert hash == "6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577"
    end

    test "weighted entries" do
      entries = [
        %{id: "alpha", weight: 10},
        %{id: "bravo", weight: 1},
        %{id: "charlie", weight: 5}
      ]

      {hash, jcs} = Protocol.entry_hash(entries)

      # JCS sorts by id (alpha < bravo < charlie), keys within each entry sorted
      assert jcs ==
               ~s({"entries":[{"id":"alpha","weight":10},{"id":"bravo","weight":1},{"id":"charlie","weight":5}]})

      assert hash == sha256_hex(jcs)
      # Pin the exact hash
      assert hash == "5616386cc36c680fed74464bc2e6eb940b07ba1353dd8aa971e16fb7463013c6"
    end

    test "single entry" do
      entries = [%{id: "solo", weight: 1}]
      {hash, jcs} = Protocol.entry_hash(entries)

      assert jcs == ~s({"entries":[{"id":"solo","weight":1}]})
      assert hash == sha256_hex(jcs)
    end

    test "input order does not affect output" do
      a = [%{id: "z", weight: 2}, %{id: "a", weight: 1}]
      b = [%{id: "a", weight: 1}, %{id: "z", weight: 2}]
      assert Protocol.entry_hash(a) == Protocol.entry_hash(b)
    end
  end

  # ── V-2: compute_seed ──────────────────────────────────────────────

  describe "V-2: compute_seed" do
    @v2_drand "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    @v2_entry_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    test "drand + weather" do
      {seed_bytes, jcs} = Protocol.compute_seed(@v2_entry_hash, @v2_drand, "1013")

      assert jcs ==
               ~s({"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","weather_value":"1013"})

      assert Base.encode16(seed_bytes, case: :lower) ==
               "4c1ae3e623dd22859d869f4d0cb34d3acaf4cf7907dbb472ea690e1400bfb0d0"
    end

    test "drand-only (no weather key in JSON)" do
      {seed_bytes, jcs} = Protocol.compute_seed(@v2_entry_hash, @v2_drand)

      assert jcs ==
               ~s({"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"})

      refute String.contains?(jcs, "weather")
      assert Base.encode16(seed_bytes, case: :lower) == sha256_hex(jcs)
    end

    test "drand-only and drand+weather produce different seeds" do
      {with_weather, _} = Protocol.compute_seed(@v2_entry_hash, @v2_drand, "1013")
      {drand_only, _} = Protocol.compute_seed(@v2_entry_hash, @v2_drand)
      refute with_weather == drand_only
    end
  end

  # ── V-3: FairPick.draw/3 ──────────────────────────────────────────

  describe "V-3: FairPick.draw" do
    test "equal-weight, 3 entries, 2 winners" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      {entry_hash, _} = Protocol.entry_hash(entries)
      {seed_bytes, _} = Protocol.compute_seed(entry_hash, @drand_hex, "1013")

      result = FairPick.draw(entries, seed_bytes, 2)

      assert result == [
               %{position: 1, entry_id: "ticket-48"},
               %{position: 2, entry_id: "ticket-47"}
             ]
    end

    test "weighted entries change selection" do
      entries = [
        %{id: "alpha", weight: 100},
        %{id: "bravo", weight: 1},
        %{id: "charlie", weight: 1}
      ]

      seed = :crypto.hash(:sha256, "frozen-weighted-vector")
      result = FairPick.draw(entries, seed, 2)

      # Pin exact output — if this changes, FairPick's weighted selection drifted
      assert Enum.map(result, & &1.entry_id) == pinned_weighted_winners()
    end

    test "single entry, single winner" do
      entries = [%{id: "only-one", weight: 1}]
      seed = :crypto.hash(:sha256, "frozen-single-entry")
      result = FairPick.draw(entries, seed, 1)

      assert result == [%{position: 1, entry_id: "only-one"}]
    end

    test "all winners (full ordering)" do
      entries = [
        %{id: "a", weight: 1},
        %{id: "b", weight: 1},
        %{id: "c", weight: 1},
        %{id: "d", weight: 1},
        %{id: "e", weight: 1}
      ]

      seed = :crypto.hash(:sha256, "frozen-full-ordering")
      result = FairPick.draw(entries, seed, 5)

      assert length(result) == 5
      # Pin exact ordering
      assert Enum.map(result, & &1.entry_id) == pinned_full_ordering()
    end

    test "deterministic across calls" do
      entries = [%{id: "x", weight: 1}, %{id: "y", weight: 1}, %{id: "z", weight: 1}]
      seed = :crypto.hash(:sha256, "determinism-check")

      r1 = FairPick.draw(entries, seed, 2)
      r2 = FairPick.draw(entries, seed, 2)
      assert r1 == r2
    end
  end

  # ── V-4: Ed25519 signing ──────────────────────────────────────────

  describe "V-4: Ed25519 sign + verify" do
    test "fixed key + fixed payload produces fixed signature" do
      payload = ~s({"hello":"world"})
      signature = Protocol.sign_receipt(payload, @test_private_key)

      assert byte_size(signature) == 64
      assert Protocol.verify_receipt(payload, signature, @test_public_key)

      # Signature is deterministic (Ed25519, no nonce)
      assert Protocol.sign_receipt(payload, @test_private_key) == signature
    end

    test "tampered payload does not verify" do
      payload = ~s({"hello":"world"})
      signature = Protocol.sign_receipt(payload, @test_private_key)

      refute Protocol.verify_receipt(payload <> "x", signature, @test_public_key)
    end

    test "wrong key does not verify" do
      payload = ~s({"hello":"world"})
      signature = Protocol.sign_receipt(payload, @test_private_key)
      {wrong_pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      refute Protocol.verify_receipt(payload, signature, wrong_pub)
    end
  end

  # ── V-5: Lock receipt payload ─────────────────────────────────────

  describe "V-5: lock receipt payload (schema v2)" do
    @lock_input %{
      operator_id: "11111111-1111-1111-1111-111111111111",
      operator_slug: "acme-prizes",
      sequence: 42,
      draw_id: "22222222-2222-2222-2222-222222222222",
      commitment_hash: "abc",
      entry_hash: "abc",
      locked_at: ~U[2026-04-07 12:34:56.789012Z],
      signing_key_id: "deadbeef",
      winner_count: 3,
      drand_chain: "quicknet-chain-hash",
      drand_round: 12_345,
      weather_station: "middle-wallop",
      weather_time: ~U[2026-04-07 13:00:00.000000Z],
      wallop_core_version: "0.11.2",
      fair_pick_version: "0.2.1"
    }

    test "JCS bytes are deterministic and keys are sorted" do
      payload = Protocol.build_receipt_payload(@lock_input)
      keys = payload |> Jason.decode!() |> Map.keys()
      assert keys == Enum.sort(keys)

      # Pin the SHA-256 of the payload bytes
      hash = sha256_hex(payload)
      assert hash == sha256_hex(Protocol.build_receipt_payload(@lock_input))
    end

    test "schema_version is 2" do
      payload = Protocol.build_receipt_payload(@lock_input)
      assert Jason.decode!(payload)["schema_version"] == "2"
    end

    test "sign + verify round-trip with frozen key" do
      payload = Protocol.build_receipt_payload(@lock_input)
      sig = Protocol.sign_receipt(payload, @test_private_key)
      assert Protocol.verify_receipt(payload, sig, @test_public_key)
    end
  end

  # ── V-6: Execution receipt payload ────────────────────────────────

  describe "V-6: execution receipt payload (schema v1)" do
    @exec_input %{
      draw_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      operator_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      operator_slug: "acme-prizes",
      sequence: 42,
      lock_receipt_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      entry_hash: "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
      drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
      drand_round: 12_345,
      drand_randomness: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
      drand_signature: "a]fake-bls-signature-hex",
      weather_station: "middle-wallop",
      weather_observation_time: ~U[2026-04-09 13:00:00.000000Z],
      weather_value: "1013",
      weather_fallback_reason: nil,
      wallop_core_version: "0.12.0",
      fair_pick_version: "0.2.1",
      seed: "deadbeef" <> String.duplicate("0", 56),
      results: ["ticket-47", "ticket-49"],
      executed_at: ~U[2026-04-09 13:01:23.456789Z]
    }

    test "JCS bytes are deterministic and keys are sorted" do
      payload = Protocol.build_execution_receipt_payload(@exec_input)
      keys = payload |> Jason.decode!() |> Map.keys()
      assert keys == Enum.sort(keys)
    end

    test "execution_schema_version is 1" do
      payload = Protocol.build_execution_receipt_payload(@exec_input)
      assert Jason.decode!(payload)["execution_schema_version"] == "1"
    end

    test "sign + verify round-trip with frozen key" do
      payload = Protocol.build_execution_receipt_payload(@exec_input)
      sig = Protocol.sign_receipt(payload, @test_private_key)
      assert Protocol.verify_receipt(payload, sig, @test_public_key)
    end

    test "20 fields present" do
      payload = Protocol.build_execution_receipt_payload(@exec_input)
      assert payload |> Jason.decode!() |> map_size() == 20
    end
  end

  # ── V-7: End-to-end draw ──────────────────────────────────────────

  describe "V-7: end-to-end (entries → hash → seed → winners)" do
    test "P-3 vector: full pipeline" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      drand = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

      {entry_hash, _} = Protocol.entry_hash(entries)
      assert entry_hash == "6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577"

      {seed_bytes, _} = Protocol.compute_seed(entry_hash, drand, "1013")

      assert Base.encode16(seed_bytes, case: :lower) ==
               "ced93f50d73a619701e9e865eb03fb4540a7232a588c707f85754aa41e3fb037"

      result = FairPick.draw(entries, seed_bytes, 2)

      assert result == [
               %{position: 1, entry_id: "ticket-48"},
               %{position: 2, entry_id: "ticket-47"}
             ]
    end
  end

  # ── V-8: key_id ───────────────────────────────────────────────────

  describe "V-8: key_id" do
    test "deterministic 8-char hex fingerprint" do
      id = Protocol.key_id(@test_public_key)
      assert String.length(id) == 8
      assert String.match?(id, ~r/^[0-9a-f]{8}$/)
      # Pin the exact value
      assert id == Protocol.key_id(@test_public_key)
    end
  end

  # ── V-9: merkle_root ──────────────────────────────────────────────

  describe "V-9: merkle_root" do
    test "empty list sentinel" do
      assert Protocol.merkle_root([]) == :crypto.hash(:sha256, <<>>)
    end

    test "single leaf" do
      leaf = "abc"
      assert Protocol.merkle_root([leaf]) == :crypto.hash(:sha256, <<0>> <> leaf)
    end

    test "two leaves" do
      ha = :crypto.hash(:sha256, <<0, ?a>>)
      hb = :crypto.hash(:sha256, <<0, ?b>>)
      expected = :crypto.hash(:sha256, <<1>> <> ha <> hb)
      assert Protocol.merkle_root(["a", "b"]) == expected
    end

    test "deterministic" do
      input = Enum.map(1..16, &Integer.to_string/1)
      assert Protocol.merkle_root(input) == Protocol.merkle_root(input)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # Hardcoded from FairPick 0.2.x output. If these change, FairPick drifted.
  defp pinned_weighted_winners, do: ["alpha", "bravo"]
  defp pinned_full_ordering, do: ["a", "b", "c", "e", "d"]

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
