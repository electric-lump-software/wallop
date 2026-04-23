defmodule WallopCore.FrozenVectorsTest do
  @moduledoc """
  PROTOCOL COMMITMENT — FROZEN TEST VECTORS

  These tests load pinned vectors from spec/vectors/*.json — the single
  source of truth shared with wallop_verifier. If any assertion fails, the
  protocol has drifted. DO NOT update expected values without:

    1. A wallop_core version bump
    2. A CHANGELOG entry with BREAKING prefix
    3. An update to spec/protocol.md
    4. Agreement that historical proofs under the old version remain
       verifiable (or an explicit decision to break them)

  Edit spec/vectors/*.json, NOT this file, to update pinned values.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol
  alias WallopCore.Transparency.AnchorWorker

  @vectors_dir Path.expand("../../../../spec/vectors", __DIR__)

  defp load_vector(filename) do
    @vectors_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  # ── Ed25519 keypair (from shared vectors) ──────────────────────────

  @ed25519 Jason.decode!(
             File.read!(Path.expand("../../../../spec/vectors/ed25519.json", __DIR__))
           )
  @test_private_key Base.decode16!(@ed25519["keypair"]["private_key_hex"], case: :mixed)
  @test_public_key Base.decode16!(@ed25519["keypair"]["public_key_hex"], case: :mixed)

  # ── V-1: entry_hash ────────────────────────────────────────────────

  describe "V-1: entry_hash" do
    setup do
      %{vectors: load_vector("entry-hash.json")["vectors"]}
    end

    # Zero-drift sentinel. This test pins the entry_hash byte output
    # against the v0.15.0 baseline — any accidental change to the
    # canonical form (sort order, JCS encoding, extra fields) breaks
    # this test loudly rather than silently re-pinning. Do NOT regenerate
    # entry-hash.json without a CHANGELOG BREAKING entry and a deliberate
    # schema_version bump on every affected receipt.
    test "single-entry canonical form is byte-pinned (v0.15.0 baseline)" do
      entries = [%{uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", weight: 1}]
      draw_id = "11111111-1111-4111-8111-111111111111"

      {hash, _jcs} = Protocol.entry_hash({draw_id, entries})

      # Frozen against the v0.15.0 vector set.
      assert hash == "d6ab8f4c63c05739f87a3cdb0d9235c09b59f4fca558a1394022e673059087e0"
    end

    @vector_names [
      "single entry",
      "operator_ref does not affect hash",
      "two entries sorted by uuid",
      "weight at 2^53-1 boundary",
      "same entries different draw_id"
    ]

    for vector_name <- @vector_names do
      @vector_name vector_name

      test @vector_name, %{vectors: vectors} do
        v = Enum.find(vectors, &(&1["name"] == @vector_name))
        refute is_nil(v), "vector not found: #{@vector_name}"

        entries =
          Enum.map(v["entries"], fn e ->
            %{uuid: e["uuid"], weight: e["weight"]}
          end)

        {hash, jcs} = Protocol.entry_hash({v["draw_id"], entries})

        assert jcs == v["expected_jcs"]
        assert hash == v["expected_hash"]
      end
    end

    test "input order does not affect output" do
      draw_id = "11111111-1111-4111-8111-111111111111"
      uuid_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      uuid_z = "ffffffff-ffff-4fff-8fff-ffffffffffff"

      a = [
        %{uuid: uuid_z, weight: 2},
        %{uuid: uuid_a, weight: 1}
      ]

      b = [
        %{uuid: uuid_a, weight: 1},
        %{uuid: uuid_z, weight: 2}
      ]

      assert Protocol.entry_hash({draw_id, a}) == Protocol.entry_hash({draw_id, b})
    end

    test "same entries in different draw_ids produce different hashes" do
      entries = [%{uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", weight: 1}]

      {h1, _} = Protocol.entry_hash({"11111111-1111-4111-8111-111111111111", entries})
      {h2, _} = Protocol.entry_hash({"22222222-2222-4222-8222-222222222222", entries})

      refute h1 == h2
    end
  end

  # ── V-2: compute_seed ──────────────────────────────────────────────

  describe "V-2: compute_seed" do
    setup do
      %{vectors: load_vector("compute-seed.json")["vectors"]}
    end

    test "drand + weather", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] == "drand + weather"))

      {seed_bytes, jcs} =
        Protocol.compute_seed(v["entry_hash"], v["drand_randomness"], v["weather_value"])

      assert jcs == v["expected_jcs"]
      assert Base.encode16(seed_bytes, case: :lower) == v["expected_seed_hex"]
    end

    test "drand-only", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "drand-only"))

      {seed_bytes, jcs} = Protocol.compute_seed(v["entry_hash"], v["drand_randomness"])

      refute String.contains?(jcs, "weather")
      assert Base.encode16(seed_bytes, case: :lower) == v["expected_seed_hex"]
    end

    test "drand-only and drand+weather produce different seeds", %{vectors: vectors} do
      v_both = Enum.find(vectors, &(&1["name"] == "drand + weather"))
      v_drand = Enum.find(vectors, &(&1["name"] =~ "drand-only"))

      {with_weather, _} =
        Protocol.compute_seed(
          v_both["entry_hash"],
          v_both["drand_randomness"],
          v_both["weather_value"]
        )

      {drand_only, _} =
        Protocol.compute_seed(v_drand["entry_hash"], v_drand["drand_randomness"])

      refute with_weather == drand_only
    end
  end

  # ── V-3: FairPick.draw/3 ──────────────────────────────────────────

  describe "V-3: FairPick.draw" do
    setup do
      %{vectors: load_vector("fair-pick.json")["vectors"]}
    end

    test "equal-weight via protocol pipeline", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "protocol pipeline"))

      entries = Enum.map(v["entries"], fn e -> %{id: e["id"], weight: e["weight"]} end)
      seed = Base.decode16!(v["seed_hex"], case: :lower)
      result = FairPick.draw(entries, seed, v["winner_count"])

      assert Enum.map(result, & &1.entry_id) == v["expected_winners"]
    end

    test "equal-weight with decoupled arbitrary seed", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "decoupled"))

      entries = Enum.map(v["entries"], fn e -> %{id: e["id"], weight: e["weight"]} end)
      seed = :crypto.hash(:sha256, "frozen-equal-weight-vector")
      result = FairPick.draw(entries, seed, v["winner_count"])

      assert Enum.map(result, & &1.entry_id) == v["expected_winners"]
    end

    test "weighted entries change selection", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "weighted"))

      entries = Enum.map(v["entries"], fn e -> %{id: e["id"], weight: e["weight"]} end)
      seed = :crypto.hash(:sha256, "frozen-weighted-vector")
      result = FairPick.draw(entries, seed, v["winner_count"])

      assert Enum.map(result, & &1.entry_id) == v["expected_winners"]
    end

    test "all winners (full ordering)", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "full ordering"))

      entries = Enum.map(v["entries"], fn e -> %{id: e["id"], weight: e["weight"]} end)
      seed = :crypto.hash(:sha256, "frozen-full-ordering")
      result = FairPick.draw(entries, seed, v["winner_count"])

      assert Enum.map(result, & &1.entry_id) == v["expected_winners"]
    end

    test "large pool — 500 entries, mixed weights (pool size 700)", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "500 entries"))

      entries = Enum.map(v["entries"], fn e -> %{id: e["id"], weight: e["weight"]} end)
      seed = Base.decode16!(v["seed_hex"], case: :lower)

      # Verify seed_hex matches seed_note derivation
      assert seed == :crypto.hash(:sha256, "large-pool-500-entries-mixed-weights")

      result = FairPick.draw(entries, seed, v["winner_count"])
      assert Enum.map(result, & &1.entry_id) == v["expected_winners"]
    end

    test "large pool — 1000 entries, 10 winners (pool size 1200)", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] =~ "1000 entries"))

      entries = Enum.map(v["entries"], fn e -> %{id: e["id"], weight: e["weight"]} end)
      seed = Base.decode16!(v["seed_hex"], case: :lower)

      # Verify seed_hex matches seed_note derivation
      assert seed == :crypto.hash(:sha256, "large-pool-1000-entries-10-winners")

      result = FairPick.draw(entries, seed, v["winner_count"])
      assert Enum.map(result, & &1.entry_id) == v["expected_winners"]
    end

    test "deterministic across calls" do
      entries = [%{id: "x", weight: 1}, %{id: "y", weight: 1}, %{id: "z", weight: 1}]
      seed = :crypto.hash(:sha256, "determinism-check")

      assert FairPick.draw(entries, seed, 2) == FairPick.draw(entries, seed, 2)
    end
  end

  # ── V-4: Ed25519 signing ──────────────────────────────────────────

  describe "V-4: Ed25519 sign + verify" do
    setup do
      %{vectors: load_vector("ed25519.json")["vectors"]}
    end

    test "fixed key + fixed payload produces fixed signature", %{vectors: vectors} do
      v = hd(vectors)

      signature = Protocol.sign_receipt(v["payload"], @test_private_key)

      assert byte_size(signature) == 64
      assert Protocol.verify_receipt(v["payload"], signature, @test_public_key)
      assert Base.encode16(signature, case: :lower) == v["expected_signature_hex"]
    end

    test "tampered payload does not verify", %{vectors: vectors} do
      v = hd(vectors)
      signature = Protocol.sign_receipt(v["payload"], @test_private_key)

      refute Protocol.verify_receipt(v["payload"] <> "x", signature, @test_public_key)
    end

    test "wrong key does not verify", %{vectors: vectors} do
      v = hd(vectors)
      signature = Protocol.sign_receipt(v["payload"], @test_private_key)
      {wrong_pub, _} = :crypto.generate_key(:eddsa, :ed25519)

      refute Protocol.verify_receipt(v["payload"], signature, wrong_pub)
    end
  end

  # ── V-5: Lock receipt payload ─────────────────────────────────────

  describe "V-5: lock receipt payload (schema v4)" do
    setup do
      %{vector: load_vector("lock-receipt.json")}
    end

    test "payload SHA-256 is pinned", %{vector: v} do
      input = to_lock_input(v["input"])
      payload = Protocol.build_receipt_payload(input)

      assert sha256_hex(payload) == v["expected_payload_sha256"]
      assert payload |> Jason.decode!() |> map_size() == v["expected_field_count"]
    end

    test "schema_version is correct", %{vector: v} do
      input = to_lock_input(v["input"])
      payload = Protocol.build_receipt_payload(input)

      assert Jason.decode!(payload)["schema_version"] == v["expected_schema_version"]
    end

    test "sign + verify round-trip with frozen key", %{vector: v} do
      input = to_lock_input(v["input"])
      payload = Protocol.build_receipt_payload(input)
      sig = Protocol.sign_receipt(payload, @test_private_key)

      assert Protocol.verify_receipt(payload, sig, @test_public_key)
    end
  end

  # ── V-6: Execution receipt payload ────────────────────────────────

  describe "V-6: execution receipt payload (schema v2)" do
    setup do
      %{vector: load_vector("execution-receipt.json")}
    end

    test "payload SHA-256 is pinned", %{vector: v} do
      input = to_exec_input(v["input"])
      payload = Protocol.build_execution_receipt_payload(input)

      assert sha256_hex(payload) == v["expected_payload_sha256"]
      assert payload |> Jason.decode!() |> map_size() == v["expected_field_count"]
    end

    test "schema_version is correct", %{vector: v} do
      input = to_exec_input(v["input"])
      payload = Protocol.build_execution_receipt_payload(input)

      assert Jason.decode!(payload)["schema_version"] == v["expected_schema_version"]
    end

    test "sign + verify round-trip with frozen key", %{vector: v} do
      input = to_exec_input(v["input"])
      payload = Protocol.build_execution_receipt_payload(input)
      sig = Protocol.sign_receipt(payload, @test_private_key)

      assert Protocol.verify_receipt(payload, sig, @test_public_key)
    end
  end

  # ── V-7: End-to-end draw ──────────────────────────────────────────

  describe "V-7: end-to-end pipeline" do
    setup do
      %{vector: load_vector("end-to-end.json")}
    end

    test "entries → hash → seed → winners", %{vector: v} do
      input = v["input"]

      entries =
        Enum.map(input["entries"], fn e ->
          %{uuid: e["uuid"], weight: e["weight"]}
        end)

      {entry_hash, _} = Protocol.entry_hash({input["draw_id"], entries})
      assert entry_hash == v["expected"]["entry_hash"]

      {seed_bytes, _} =
        Protocol.compute_seed(
          entry_hash,
          input["drand_randomness"],
          input["weather_value"]
        )

      assert Base.encode16(seed_bytes, case: :lower) == v["expected"]["seed_hex"]

      fair_pick_entries = Enum.map(entries, &%{id: &1.uuid, weight: &1.weight})
      result = FairPick.draw(fair_pick_entries, seed_bytes, input["winner_count"])
      assert Enum.map(result, & &1.entry_id) == v["expected"]["winners"]
    end
  end

  # ── V-8: key_id ───────────────────────────────────────────────────

  describe "V-8: key_id" do
    setup do
      %{vectors: load_vector("key-id.json")["vectors"]}
    end

    test "deterministic fingerprint pinned", %{vectors: vectors} do
      v = hd(vectors)
      pub = Base.decode16!(v["public_key_hex"], case: :mixed)

      assert Protocol.key_id(pub) == v["expected_key_id"]
    end
  end

  # ── V-9: merkle_root ──────────────────────────────────────────────

  describe "V-9: merkle_root" do
    setup do
      %{vectors: load_vector("merkle-root.json")["vectors"]}
    end

    test "empty list sentinel" do
      assert Protocol.merkle_root([]) == :crypto.hash(:sha256, <<>>)
    end

    test "two leaves pinned", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] == "two leaves"))
      root = Protocol.merkle_root(v["leaves"])

      assert Base.encode16(root, case: :lower) == v["expected_root_hex"]
    end

    test "16 leaves pinned", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] == "16 leaves"))
      root = Protocol.merkle_root(v["leaves"])

      assert Base.encode16(root, case: :lower) == v["expected_root_hex"]
    end
  end

  # ── V-10: anchor combined root ────────────────────────────────────

  describe "V-10: anchor combined root" do
    setup do
      %{vectors: load_vector("anchor-root.json")["vectors"]}
    end

    test "SHA256(prefix || op_root || exec_root) pinned", %{vectors: vectors} do
      v = Enum.find(vectors, &(&1["name"] == "known sub-tree roots"))

      op_root = Base.decode16!(v["operator_receipts_root_hex"], case: :lower)
      exec_root = Base.decode16!(v["execution_receipts_root_hex"], case: :lower)
      combined = AnchorWorker.combined_root(op_root, exec_root)

      assert Base.encode16(combined, case: :lower) == v["expected_combined_root_hex"]
    end

    test "prefix is raw UTF-8 bytes, not length-prefixed" do
      dummy = <<0::256>>
      expected = :crypto.hash(:sha256, "wallop-anchor-v1" <> dummy <> dummy)
      assert AnchorWorker.combined_root(dummy, dummy) == expected
    end
  end

  # ── V-11: cross-receipt linkage ────────────────────────────────────

  describe "V-11: cross-receipt linkage" do
    setup do
      %{vector: load_vector("cross-receipt-linkage.json")}
    end

    test "lock receipt → SHA-256 → lock_receipt_hash", %{vector: v} do
      input = to_lock_input(v["lock_receipt_input"])
      payload = Protocol.build_receipt_payload(input)
      hash = sha256_hex(payload)

      assert hash == v["expected_lock_payload_sha256"]
    end
  end

  # ── V-12: drand-only execution receipt ─────────────────────────────

  describe "V-12: drand-only execution receipt" do
    setup do
      %{vector: load_vector("execution-receipt-drand-only.json")}
    end

    test "null weather fields are present as JSON null, not omitted", %{vector: v} do
      input = to_exec_input(v["input"])
      payload = Protocol.build_execution_receipt_payload(input)
      decoded = Jason.decode!(payload)

      assert Map.has_key?(decoded, "weather_station")
      assert Map.has_key?(decoded, "weather_observation_time")
      assert Map.has_key?(decoded, "weather_value")
      assert decoded["weather_station"] == nil
      assert decoded["weather_observation_time"] == nil
      assert decoded["weather_value"] == nil
      assert decoded["weather_fallback_reason"] == "unreachable"
    end

    test "payload SHA-256 is pinned", %{vector: v} do
      input = to_exec_input(v["input"])
      payload = Protocol.build_execution_receipt_payload(input)

      assert sha256_hex(payload) == v["expected_payload_sha256"]
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp to_lock_input(map) do
    %{
      operator_id: map["operator_id"],
      operator_slug: map["operator_slug"],
      sequence: map["sequence"],
      draw_id: map["draw_id"],
      commitment_hash: map["commitment_hash"],
      entry_hash: map["entry_hash"],
      locked_at: parse_datetime!(map["locked_at"]),
      signing_key_id: map["signing_key_id"],
      winner_count: map["winner_count"],
      drand_chain: map["drand_chain"],
      drand_round: map["drand_round"],
      weather_station: map["weather_station"],
      weather_time: parse_datetime(map["weather_time"]),
      wallop_core_version: map["wallop_core_version"],
      fair_pick_version: map["fair_pick_version"]
    }
  end

  defp to_exec_input(map) do
    %{
      draw_id: map["draw_id"],
      operator_id: map["operator_id"],
      operator_slug: map["operator_slug"],
      sequence: map["sequence"],
      lock_receipt_hash: map["lock_receipt_hash"],
      entry_hash: map["entry_hash"],
      drand_chain: map["drand_chain"],
      drand_round: map["drand_round"],
      drand_randomness: map["drand_randomness"],
      drand_signature: map["drand_signature"],
      weather_station: map["weather_station"],
      weather_observation_time: parse_datetime(map["weather_observation_time"]),
      weather_value: map["weather_value"],
      weather_fallback_reason: map["weather_fallback_reason"],
      wallop_core_version: map["wallop_core_version"],
      fair_pick_version: map["fair_pick_version"],
      seed: map["seed"],
      results: map["results"],
      executed_at: parse_datetime!(map["executed_at"])
    }
  end

  defp parse_datetime!(str), do: DateTime.from_iso8601(str) |> elem(1)
  defp parse_datetime(nil), do: nil
  defp parse_datetime(str), do: parse_datetime!(str)

  describe "V-13: proof bundle shape" do
    test "frozen proof-bundle.json has the expected top-level keys" do
      bundle = load_vector("proof-bundle.json")

      assert bundle["version"] == 1
      assert is_binary(bundle["draw_id"])
      assert is_list(bundle["entries"])
      assert is_list(bundle["results"])
      assert is_map(bundle["entropy"])
      assert is_map(bundle["lock_receipt"])
      assert is_map(bundle["execution_receipt"])

      assert bundle["entropy"]["drand_round"]
      assert bundle["entropy"]["drand_randomness"]
      assert bundle["entropy"]["drand_signature"]
      assert bundle["entropy"]["drand_chain_hash"]
      assert bundle["entropy"]["weather_value"]

      assert bundle["lock_receipt"]["payload_jcs"]
      assert bundle["lock_receipt"]["signature_hex"]
      assert bundle["lock_receipt"]["operator_public_key_hex"]

      assert bundle["execution_receipt"]["payload_jcs"]
      assert bundle["execution_receipt"]["signature_hex"]
      assert bundle["execution_receipt"]["infrastructure_public_key_hex"]
    end

    test "frozen proof-bundle-drand-only.json omits weather_value entirely" do
      bundle = load_vector("proof-bundle-drand-only.json")

      assert bundle["version"] == 1
      assert is_map(bundle["entropy"])
      assert bundle["entropy"]["drand_randomness"]
      assert bundle["entropy"]["drand_signature"]

      # Critical: weather_value must be ABSENT, not null. The CLI verifier
      # branches on key presence to choose compute_seed vs compute_seed_drand_only.
      refute Map.has_key?(bundle["entropy"], "weather_value")
    end
  end
end
