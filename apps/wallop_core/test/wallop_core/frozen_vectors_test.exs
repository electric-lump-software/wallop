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
    - key_id fingerprint
    - merkle_root (RFC 6962)

  See also: FairPick.FrozenVectorsTest in the fair_pick repo for
  algorithm-level vectors decoupled from wallop_core Protocol functions.
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

      assert jcs ==
               ~s({"entries":[{"id":"alpha","weight":10},{"id":"bravo","weight":1},{"id":"charlie","weight":5}]})

      assert hash == "5616386cc36c680fed74464bc2e6eb940b07ba1353dd8aa971e16fb7463013c6"
    end

    test "single entry" do
      entries = [%{id: "solo", weight: 1}]
      {hash, _jcs} = Protocol.entry_hash(entries)
      assert hash == "6df489f98b5dac2a004bdee59e589b4626c9f7c4126e5242c1989335f6dd5d13"
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

    test "drand-only" do
      {seed_bytes, jcs} = Protocol.compute_seed(@v2_entry_hash, @v2_drand)

      assert jcs ==
               ~s({"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"})

      refute String.contains?(jcs, "weather")

      assert Base.encode16(seed_bytes, case: :lower) ==
               "54f79b8158769d6aba6fa762bb33dce5d9bd1d8986b6285beb12b1c30f020b17"
    end

    test "drand-only and drand+weather produce different seeds" do
      {with_weather, _} = Protocol.compute_seed(@v2_entry_hash, @v2_drand, "1013")
      {drand_only, _} = Protocol.compute_seed(@v2_entry_hash, @v2_drand)
      refute with_weather == drand_only
    end
  end

  # ── V-3: FairPick.draw/3 ──────────────────────────────────────────

  describe "V-3: FairPick.draw" do
    test "equal-weight via protocol pipeline" do
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

    test "equal-weight with decoupled arbitrary seed" do
      entries = [
        %{id: "ticket-47", weight: 1},
        %{id: "ticket-48", weight: 1},
        %{id: "ticket-49", weight: 1}
      ]

      seed = :crypto.hash(:sha256, "frozen-equal-weight-vector")
      result = FairPick.draw(entries, seed, 2)

      assert Enum.map(result, & &1.entry_id) == ["ticket-49", "ticket-47"]
    end

    test "weighted entries change selection" do
      entries = [
        %{id: "alpha", weight: 100},
        %{id: "bravo", weight: 1},
        %{id: "charlie", weight: 1}
      ]

      seed = :crypto.hash(:sha256, "frozen-weighted-vector")
      result = FairPick.draw(entries, seed, 2)

      assert Enum.map(result, & &1.entry_id) == ["alpha", "bravo"]
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
      assert Enum.map(result, & &1.entry_id) == ["a", "b", "c", "e", "d"]
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

      # Pin the exact signature bytes
      assert Base.encode16(signature, case: :lower) ==
               "b86d1d6a0ac79fd8af966d14191c6dab4f85a16310d9b079ce2a0cabb6301e4e0f52c5c9c85053232eb46aa039f2cfcea0b669554e51c41c9cfef534cd2e570c"
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

    test "payload SHA-256 is pinned (any serialization drift fails this)" do
      payload = Protocol.build_receipt_payload(@lock_input)

      assert sha256_hex(payload) ==
               "cc268c285bd6df5a6acfd56034b4a2a1f191e7e4db41ec7b675a306149f39724"

      assert payload |> Jason.decode!() |> map_size() == 16
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

    test "payload SHA-256 is pinned (any serialization drift fails this)" do
      payload = Protocol.build_execution_receipt_payload(@exec_input)

      assert sha256_hex(payload) ==
               "38f04bb616c97e960f9ab04d565deb805e66e6fdfb1f5ebe8a9cebb4683c8f72"

      assert payload |> Jason.decode!() |> map_size() == 20
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
    test "deterministic 8-char hex fingerprint pinned to exact value" do
      id = Protocol.key_id(@test_public_key)
      assert id == "21fe31df"
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

    test "two leaves pinned" do
      root = Protocol.merkle_root(["a", "b"])

      assert Base.encode16(root, case: :lower) ==
               "b137985ff484fb600db93107c77b0365c80d78f5b429ded0fd97361d077999eb"
    end

    test "16 leaves pinned" do
      input = Enum.map(1..16, &Integer.to_string/1)

      assert Protocol.merkle_root(input) |> Base.encode16(case: :lower) ==
               "5b20458a9dfa66ab1990467a95cbd7af502caf09cd2ff620725cdb314b52d443"
    end
  end

  # ── V-10: anchor combined root ──────────────────────────────────────
  # Requested by wallop_rs for cross-implementation verification.
  # The prefix is raw UTF-8 bytes of "wallop-anchor-v1", no length-prefixing.

  describe "V-10: anchor combined root" do
    test "SHA256(\"wallop-anchor-v1\" || op_root || exec_root) pinned" do
      op_root = :crypto.hash(:sha256, "operator-receipts-sentinel")
      exec_root = :crypto.hash(:sha256, "execution-receipts-sentinel")

      combined = WallopCore.Transparency.AnchorWorker.combined_root(op_root, exec_root)

      assert Base.encode16(op_root, case: :lower) ==
               "15608de04e527005cd03f96a456269aaf9dc068996612d7f5b2ea11d0bc453ac"

      assert Base.encode16(exec_root, case: :lower) ==
               "f83eba0b2ff61a29603ce50f0a69573944108cc876a461e881d6dbb2270204c2"

      assert Base.encode16(combined, case: :lower) ==
               "3512c7c5af6f533c5acc9aa42b1368b9c42a7bf265229df5083166740d0e130f"
    end

    test "prefix is raw UTF-8 bytes, not length-prefixed" do
      # Verifiers must concatenate exactly: "wallop-anchor-v1" <> op_root <> exec_root
      # then SHA-256 the result. No length prefix on the tag.
      dummy = <<0::256>>

      expected = :crypto.hash(:sha256, "wallop-anchor-v1" <> dummy <> dummy)
      actual = WallopCore.Transparency.AnchorWorker.combined_root(dummy, dummy)

      assert actual == expected
    end
  end

  # ── V-11: cross-receipt linkage ────────────────────────────────────
  # Requested by wallop_rs. Pins the chain:
  # lock receipt JCS → SHA-256 → lock_receipt_hash in execution receipt

  describe "V-11: cross-receipt linkage" do
    @linkage_lock_input %{
      operator_id: "11111111-1111-1111-1111-111111111111",
      operator_slug: "acme-prizes",
      sequence: 1,
      draw_id: "22222222-2222-2222-2222-222222222222",
      commitment_hash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      entry_hash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      locked_at: ~U[2026-04-09 12:00:00.000000Z],
      signing_key_id: "deadbeef",
      winner_count: 2,
      drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
      drand_round: 12_345,
      weather_station: "middle-wallop",
      weather_time: ~U[2026-04-09 12:10:00.000000Z],
      wallop_core_version: "0.14.1",
      fair_pick_version: "0.2.1"
    }

    test "lock receipt payload → SHA-256 → lock_receipt_hash is pinned" do
      lock_payload = Protocol.build_receipt_payload(@linkage_lock_input)
      lock_hash = sha256_hex(lock_payload)

      assert lock_hash ==
               "3e05d89b6674e825d2b1badc83ac26d6e59272bc84e5742d5d5bd482bb81468a"
    end

    test "execution receipt uses the same lock_receipt_hash" do
      lock_payload = Protocol.build_receipt_payload(@linkage_lock_input)
      lock_hash = sha256_hex(lock_payload)

      exec_input = %{
        draw_id: "22222222-2222-2222-2222-222222222222",
        operator_id: "11111111-1111-1111-1111-111111111111",
        operator_slug: "acme-prizes",
        sequence: 1,
        lock_receipt_hash: lock_hash,
        entry_hash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
        drand_round: 12_345,
        drand_randomness: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        drand_signature: "deadbeef-bls-signature",
        weather_station: "middle-wallop",
        weather_observation_time: ~U[2026-04-09 12:10:00.000000Z],
        weather_value: "1013",
        weather_fallback_reason: nil,
        wallop_core_version: "0.14.1",
        fair_pick_version: "0.2.1",
        seed: "aaaa" <> String.duplicate("0", 60),
        results: ["ticket-48", "ticket-47"],
        executed_at: ~U[2026-04-09 12:05:00.000000Z]
      }

      exec_payload = Protocol.build_execution_receipt_payload(exec_input)
      decoded = Jason.decode!(exec_payload)

      # The lock_receipt_hash in the execution receipt must equal
      # SHA-256 of the lock receipt's JCS payload bytes
      assert decoded["lock_receipt_hash"] == lock_hash
    end
  end

  # ── V-12: drand-only execution receipt (null weather fields) ───────
  # Requested by wallop_rs. JCS null serialization is a classic
  # cross-implementation divergence point.

  describe "V-12: drand-only execution receipt" do
    test "null weather fields are present as JSON null, not omitted" do
      input = %{
        draw_id: "22222222-2222-2222-2222-222222222222",
        operator_id: "11111111-1111-1111-1111-111111111111",
        operator_slug: "acme-prizes",
        sequence: 1,
        lock_receipt_hash: "3e05d89b6674e825d2b1badc83ac26d6e59272bc84e5742d5d5bd482bb81468a",
        entry_hash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
        drand_round: 12_345,
        drand_randomness: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        drand_signature: "deadbeef-bls-signature",
        weather_station: nil,
        weather_observation_time: nil,
        weather_value: nil,
        weather_fallback_reason: "met_office_timeout",
        wallop_core_version: "0.14.1",
        fair_pick_version: "0.2.1",
        seed: "aaaa" <> String.duplicate("0", 60),
        results: ["ticket-48", "ticket-47"],
        executed_at: ~U[2026-04-09 12:05:00.000000Z]
      }

      payload = Protocol.build_execution_receipt_payload(input)
      decoded = Jason.decode!(payload)

      # Keys MUST be present with null values, not omitted
      assert Map.has_key?(decoded, "weather_station")
      assert Map.has_key?(decoded, "weather_observation_time")
      assert Map.has_key?(decoded, "weather_value")

      assert decoded["weather_station"] == nil
      assert decoded["weather_observation_time"] == nil
      assert decoded["weather_value"] == nil
      assert decoded["weather_fallback_reason"] == "met_office_timeout"
    end

    test "drand-only payload SHA-256 is pinned" do
      input = %{
        draw_id: "22222222-2222-2222-2222-222222222222",
        operator_id: "11111111-1111-1111-1111-111111111111",
        operator_slug: "acme-prizes",
        sequence: 1,
        lock_receipt_hash: "3e05d89b6674e825d2b1badc83ac26d6e59272bc84e5742d5d5bd482bb81468a",
        entry_hash: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
        drand_round: 12_345,
        drand_randomness: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        drand_signature: "deadbeef-bls-signature",
        weather_station: nil,
        weather_observation_time: nil,
        weather_value: nil,
        weather_fallback_reason: "met_office_timeout",
        wallop_core_version: "0.14.1",
        fair_pick_version: "0.2.1",
        seed: "aaaa" <> String.duplicate("0", 60),
        results: ["ticket-48", "ticket-47"],
        executed_at: ~U[2026-04-09 12:05:00.000000Z]
      }

      payload = Protocol.build_execution_receipt_payload(input)

      assert sha256_hex(payload) ==
               "3c847e0c73bf65695f66966524029f23c8be3ac6544a6f54e0a03239b4e8ac12"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
