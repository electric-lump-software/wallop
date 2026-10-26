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

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Transparency.AnchorWorker
  alias WallopCore.Weather.LandObsGrammar

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

  describe "V-5: lock receipt payload (schema v5)" do
    # wallop_core 0.20.0+ produces lock receipts at schema v5, which omits
    # the inline `operator_public_key_hex` from the bundle wrapper and
    # signals to verifiers that operator keys MUST be resolved via
    # `KeyResolver` (spec §4.2.4). Field set on the signed payload is
    # byte-identical to v4 — the schema_version difference encodes
    # verifier behaviour, not receipt bytes. The historical v4 vector
    # `lock-receipt.json` is preserved on disk and exercised by the Rust
    # verifier's v4 parser for backwards compatibility (receipts signed
    # under v0.19.x remain verifiable for the life of 1.x).
    setup do
      %{vector: load_vector("lock-receipt-v5.json")}
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

  describe "V-6: execution receipt payload (schema v4)" do
    # wallop_core 0.20.0+ produces execution receipts at schema v4, which
    # mirrors lock v5: the bundle wrapper omits `infrastructure_public_key_hex`
    # and verifiers MUST resolve infra keys via `KeyResolver` (spec §4.2.4).
    # Field set on the signed payload is byte-identical to v3 — the
    # schema_version difference encodes verifier behaviour, not receipt
    # bytes. The historical v3 and v2 vectors (`execution-receipt-v3.json`,
    # `execution-receipt.json`) are preserved on disk and exercised by the
    # Rust verifier's v3 / v2 parsers for backwards compatibility.
    setup do
      %{vector: load_vector("execution-receipt-v4.json")}
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

    test "signing_key_id is committed in the signed payload", %{vector: v} do
      input = to_exec_input(v["input"])
      payload = Protocol.build_execution_receipt_payload(input)

      assert Jason.decode!(payload)["signing_key_id"] == v["input"]["signing_key_id"]
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
      %{vector: load_vector("cross-receipt-linkage-v5.json")}
    end

    test "lock receipt → SHA-256 → lock_receipt_hash", %{vector: v} do
      input = to_lock_input(v["lock_receipt_input"])
      payload = Protocol.build_receipt_payload(input)
      hash = sha256_hex(payload)

      assert hash == v["expected_lock_payload_sha256"]
    end
  end

  # ── V-12: drand-only execution receipt ─────────────────────────────

  describe "V-12: drand-only execution receipt (schema v4)" do
    setup do
      %{vector: load_vector("execution-receipt-drand-only-v4.json")}
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
      executed_at: parse_datetime!(map["executed_at"]),
      signing_key_id: map["signing_key_id"]
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
      assert bundle["execution_receipt"]["payload_jcs"]
      assert bundle["execution_receipt"]["signature_hex"]
    end

    test "the v5 proof bundles are lock 5 / execution 4, resolver-driven, on a real round" do
      for file <- ["proof-bundle.json", "proof-bundle-drand-only.json"] do
        bundle = load_vector(file)
        lock = Jason.decode!(bundle["lock_receipt"]["payload_jcs"])
        exec = Jason.decode!(bundle["execution_receipt"]["payload_jcs"])

        assert {lock["schema_version"], exec["schema_version"]} == {"5", "4"}, file
        refute Map.has_key?(bundle["lock_receipt"], "operator_public_key_hex"), file
        refute Map.has_key?(bundle["execution_receipt"], "infrastructure_public_key_hex"), file

        assert_real_beacon(bundle["entropy"], file)
        assert exec["drand_signature"] == bundle["entropy"]["drand_signature"], file
        {:ok, locked_at, 0} = DateTime.from_iso8601(lock["locked_at"])
        published = Quicknet.pub_time(lock["drand_round"])
        assert DateTime.compare(published, locked_at) == :gt, file
      end
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

  # ── Lock v6 / execution v5: observation weather and grid frequency ──

  @landobs_tag "drand-quicknet+metoffice-landobs-v1"
  @freq_tag "drand-quicknet+elexon-freq-v1"

  @required_negative_names ~w(
    weather_time_not_whole_hour weather_time_not_calendar weather_time_not_derived_from_round
    locked_at_after_latest_lock_at round_published_before_lock lock_station_not_middle_wallop
    exec_station_not_middle_wallop exec_station_wittering observation_time_not_weather_time
    partial_fallback_value_null_reason_null partial_fallback_reason_set_value_set
    value_grammar_minus_zero value_grammar_leading_zero value_grammar_three_parts
    value_out_of_bounds v5_reason_in_v6_exec wrong_entropy_composition
    wrong_entropy_composition_exec lock_v6_with_exec_v4 lock_v5_with_exec_v5
    inline_key_on_lock_v6 inline_key_on_exec_v5 executed_before_round_published
    weather_with_freq_value weather_with_freq_fallback_reason
    freq_fallback_value_null_reason_null freq_value_without_weather_fallback_reason
    freq_start_plus_15s freq_start_plus_15s_on_freq_fallback freq_start_off_grid
    freq_start_null freq_start_missing freq_bundle_relabelled_landobs
    unknown_v6_tag entropy_composition_mismatch
    observation_time_without_weather_value freq_window_with_weather_value
    freq_window_with_observation_time fallback_with_weather_value
    fallback_with_observation_time fallback_executed_before_round_published
    freq_start_not_derived_from_round freq_start_not_on_grid freq_locked_at_after_latest_lock_at
    freq_round_published_before_lock freq_value_and_reason freq_value_null_reason_null
    freq_weather_reason freq_value_stuck_run freq_value_zero_reading freq_value_out_of_bounds
    freq_value_four_digits weather_value_under_freq_tag weather_station_under_freq_tag
    freq_lock_with_landobs_exec landobs_lock_with_freq_exec unknown_freq_tag
    freq_executed_before_round_published freq_entropy_value_mismatch
  )

  # The verifier's step names, in their snake_case wire form.
  @step_names ~w(bundle_shape lock_signature exec_signature weather_observation_window
                 receipt_field_consistency drand_bls_signature entry_hash seed_recomputation
                 winner_selection)

  # {file, tag, landobs state or nil}
  @v6_receipt_vectors [
    {"lock-receipt-v6.json", @landobs_tag, nil},
    {"execution-receipt-v5.json", @landobs_tag, "a"},
    {"execution-receipt-freq-window-v5.json", @landobs_tag, "b"},
    {"execution-receipt-fallback-v5.json", @landobs_tag, "c"},
    {"lock-receipt-v6-freq.json", @freq_tag, nil},
    {"execution-receipt-v5-freq.json", @freq_tag, nil},
    {"execution-receipt-fallback-v5-freq.json", @freq_tag, nil}
  ]

  # {file, tag, landobs state or nil, lock receipt vector, exec receipt vector}
  @v6_bundle_vectors [
    {"proof-bundle-v6.json", @landobs_tag, "a", "lock-receipt-v6.json",
     "execution-receipt-v5.json"},
    {"proof-bundle-v6-freq-window.json", @landobs_tag, "b", "lock-receipt-v6.json",
     "execution-receipt-freq-window-v5.json"},
    {"proof-bundle-v6-fallback.json", @landobs_tag, "c", "lock-receipt-v6.json",
     "execution-receipt-fallback-v5.json"},
    {"proof-bundle-v6-freq.json", @freq_tag, nil, "lock-receipt-v6-freq.json",
     "execution-receipt-v5-freq.json"},
    {"proof-bundle-v6-freq-fallback.json", @freq_tag, nil, "lock-receipt-v6-freq.json",
     "execution-receipt-fallback-v5-freq.json"}
  ]

  describe "observation weather vectors" do
    alias WallopCore.Weather.{Schedule, Stations}

    test "weather-schedule-landobs-v1.json matches Schedule and the tag constants" do
      v = load_vector("weather-schedule-landobs-v1.json")
      assert v["entropy_composition"] == Protocol.landobs_entropy_composition()
      assert v["stations"] == Stations.ids()
      assert v["stations"] == ["wmo-03749"]
      assert v["w_secs"] == Schedule.fetch_window_seconds()
      assert v["publish_margin_secs"] == 60
      assert v["lock_offset_secs"] == Schedule.lock_offset_seconds()

      for c <- v["cases"] do
        round = c["drand_round"]
        wt = Schedule.weather_time_for_round(round)
        assert usec(Quicknet.pub_time(round)) == c["published_at"], inspect(c)
        assert usec(wt) == c["weather_time"], inspect(c)
        assert usec(Schedule.latest_lock_at(wt)) == c["latest_lock_at"], inspect(c)

        assert usec(WallopCore.Frequency.Schedule.freq_start_for_round(round)) ==
                 c["freq_start"],
               inspect(c)
      end

      # A round exactly at the bound (pub = h + W + 60 s) and the round before it.
      at_bound =
        Enum.find(v["cases"], fn c ->
          {:ok, pub, 0} = DateTime.from_iso8601(c["published_at"])
          {:ok, wt, 0} = DateTime.from_iso8601(c["weather_time"])
          DateTime.diff(pub, wt) == v["w_secs"] + v["publish_margin_secs"]
        end)

      assert at_bound
      before = Enum.find(v["cases"], &(&1["drand_round"] == at_bound["drand_round"] - 1))
      {:ok, wt, 0} = DateTime.from_iso8601(at_bound["weather_time"])
      assert before["weather_time"] == usec(DateTime.add(wt, -3600))
    end

    test "weather-value-landobs-v1.json matches the grammar" do
      alias WallopCore.Weather.LandObsGrammar, as: G
      # Read with the grammar's own decoder so the from_row numbers keep their
      # text: a float-based JSON reader would turn 60.0 into 60 and refuse 1e400.
      {:ok, v} = G.decode(File.read!(vector_path("weather-value-landobs-v1.json")))
      b = G.bounds()

      assert v["bounds"] == %{
               "t" => [{:number, "-900"}, {:number, "600"}],
               "mslp" => [{:number, "850"}, {:number, "1100"}],
               "rh" => [{:number, "0"}, {:number, "100"}],
               "vis" => [{:number, "0"}, {:number, "10000"}]
             }

      assert {b.t, b.mslp, b.rh, b.vis} == {-900..600, 850..1100, 0..100, 0..10_000}

      for c <- v["valid"] do
        assert G.valid_value?(c["value"]), c["value"]

        parts =
          Enum.map(["t", "mslp", "rh", "vis"], fn k ->
            {:number, text} = c[k]
            text
          end)

        assert Enum.join(parts, ";") == c["value"]
      end

      for c <- v["invalid"], do: refute(G.valid_value?(c["value"]), c["reason"])

      assert length(v["from_row"]) > 40

      for c <- v["from_row"] do
        case c do
          %{"expected_value" => value} ->
            assert G.canonical_value(c["row"]) == {:ok, value}, inspect(c)

          %{"expected_error" => true} ->
            assert {:error, _} = G.canonical_value(c["row"]), inspect(c)
        end
      end
    end

    test "landobs receipt vectors rebuild byte-for-byte, in their states" do
      for {file, @landobs_tag, state} <- @v6_receipt_vectors do
        v = load_vector(file)
        assert_receipt_vector(v, file)
        payload = Jason.decode!(v["payload_jcs"])
        assert payload["weather_station"] == "wmo-03749", file
        assert payload["entropy_composition"] == @landobs_tag, file

        if state do
          input = atomize_receipt_input(v["input"])

          assert LandObs.exec_state(input) ==
                   {:ok, landobs_state(state)},
                 file
        end
      end
    end

    test "landobs proof bundles carry the receipt vectors and recompute" do
      for {file, @landobs_tag, state, lock_file, exec_file} <- @v6_bundle_vectors do
        assert_bundle_vector(file, lock_file, exec_file, state)
      end
    end

    test "no state (b) file is a grid-frequency tag file, and there is no backup bundle" do
      refute File.exists?(vector_path("proof-bundle-v6-backup.json"))

      for file <- ["execution-receipt-freq-window-v5.json", "proof-bundle-v6-freq-window.json"] do
        assert String.starts_with?(load_vector(file)["description"], "#{@landobs_tag}, state (b)")
      end
    end
  end

  describe "grid frequency vectors" do
    alias WallopCore.Frequency.{FreqGrammar, Schedule}

    test "frequency-schedule-elexon-v1.json matches Schedule and the tag constants" do
      v = load_vector("frequency-schedule-elexon-v1.json")
      assert v["entropy_composition"] == Protocol.freq_entropy_composition()
      assert v["readings"] == Schedule.readings()
      assert v["spacing_secs"] == Schedule.spacing_seconds()
      assert v["w_freq_secs"] == Schedule.fetch_window_seconds()
      assert v["margin_secs"] == Schedule.margin_seconds()
      assert v["lock_gap_secs"] == Schedule.lock_gap_seconds()
      assert v["stuck_run"] == FreqGrammar.stuck_run()
      assert v["bounds_mhz"] == [FreqGrammar.bounds().first, FreqGrammar.bounds().last]

      for c <- v["cases"] do
        round = c["drand_round"]
        t = Schedule.freq_start_for_round(round)
        assert usec(Quicknet.pub_time(round)) == c["published_at"], inspect(c)
        assert usec(t) == c["freq_start"], inspect(c)
        assert usec(Schedule.fetch_deadline(t)) == c["fetch_deadline"], inspect(c)
        assert usec(Schedule.latest_lock_at(t)) == c["latest_lock_at"], inspect(c)
      end
    end

    test "frequency-value-elexon-v1.json matches the grammar" do
      alias WallopCore.Frequency.FreqGrammar, as: G
      v = load_vector("frequency-value-elexon-v1.json")
      assert v["bounds_mhz"] == [G.bounds().first, G.bounds().last]
      assert v["stuck_run"] == G.stuck_run()

      for value <- v["valid"], do: assert(G.valid_value?(value), value)
      for c <- v["invalid"], do: refute(G.valid_value?(c["value"]), c["reason"])

      for c <- v["readings"] do
        {:ok, %{"f" => number}} = G.decode(~s({"f":#{c["text"]}}))

        case c do
          %{"expected_mhz" => mhz} -> assert G.reading_mhz(number) == {:ok, mhz}, c["text"]
          %{"expected_error" => true} -> assert {:error, _} = G.reading_mhz(number), c["text"]
        end
      end

      for c <- v["from_rows"] do
        {:ok, t, 0} = DateTime.from_iso8601(c["freq_start"])

        rows =
          Enum.map_join(c["rows"], ",", fn [time, text] ->
            ~s({"measurementTime":"#{time}","frequency":#{text}})
          end)

        {:ok, %{"data" => decoded}} = G.decode(~s({"data":[#{rows}]}))

        case c do
          %{"expected_value" => value} ->
            assert G.window_from_rows(decoded, t) == {:ok, value}, inspect(c)

          %{"expected_error" => true} ->
            assert {:error, _} = G.window_from_rows(decoded, t), inspect(c)
        end
      end
    end

    test "frequency receipt vectors rebuild byte-for-byte" do
      for {file, @freq_tag, nil} <- @v6_receipt_vectors do
        v = load_vector(file)
        assert_receipt_vector(v, file)
        payload = Jason.decode!(v["payload_jcs"])
        assert payload["entropy_composition"] == @freq_tag, file

        for key <- ~w(weather_station weather_time weather_value weather_observation_time
                      weather_fallback_reason),
            Map.has_key?(payload, key),
            do: assert(is_nil(payload[key]), "#{file} #{key}")
      end
    end

    test "frequency proof bundles carry the receipt vectors and recompute" do
      for {file, @freq_tag, nil, lock_file, exec_file} <- @v6_bundle_vectors do
        assert_bundle_vector(file, lock_file, exec_file, nil)
      end
    end
  end

  describe "shared lock v6 / execution v5 vectors" do
    test "regenerated receipts commit to rounds published after locked_at" do
      for {file, path} <- [
            {"lock-receipt.json", ["input"]},
            {"lock-receipt-v5.json", ["input"]},
            {"cross-receipt-linkage.json", ["lock_receipt_input"]},
            {"cross-receipt-linkage-v5.json", ["lock_receipt_input"]},
            {"lock-receipt-v6.json", ["input"]},
            {"lock-receipt-v6-freq.json", ["input"]}
          ] do
        input = get_in(load_vector(file), path)
        {:ok, locked_at, 0} = DateTime.from_iso8601(input["locked_at"])
        published = Quicknet.pub_time(input["drand_round"])
        assert DateTime.compare(published, locked_at) == :gt, file
      end
    end

    test "the negative set names every required case, each with an exact set of known steps" do
      v = load_vector("proof-bundle-v6-negative.json")
      names = Enum.map(v["cases"], & &1["name"])
      assert names == Enum.uniq(names)
      assert MapSet.subset?(MapSet.new(@required_negative_names), MapSet.new(names))

      for %{"name" => name, "expected_failing_steps" => steps} <- v["cases"] do
        assert steps != [], name
        assert steps == Enum.sort(Enum.uniq(steps)), name
        assert Enum.all?(steps, &(&1 in @step_names)), name
      end
    end

    test "every negative bundle is signed by the vector keys, so only the semantic checks refuse it" do
      v = load_vector("proof-bundle-v6-negative.json")
      keys = keys_by_class(v["keys"])

      for %{"name" => name, "bundle" => text} <- v["cases"] do
        bundle = Jason.decode!(text)
        assert_signed(bundle, keys, name)
      end
    end

    test "every new file's description starts with its tag (and state)" do
      for {file, tag, state} <-
            [
              {"weather-schedule-landobs-v1.json", @landobs_tag, nil},
              {"weather-value-landobs-v1.json", @landobs_tag, nil},
              {"frequency-schedule-elexon-v1.json", @freq_tag, nil},
              {"frequency-value-elexon-v1.json", @freq_tag, nil}
            ] ++
              Enum.map(@v6_receipt_vectors, fn {f, t, s} -> {f, t, s} end) ++
              Enum.map(@v6_bundle_vectors, fn {f, t, s, _, _} -> {f, t, s} end) do
        prefix = if state, do: "#{tag}, state (#{state}): ", else: tag
        assert String.starts_with?(description(file), prefix), file
      end

      assert load_vector("proof-bundle-v6-negative.json")["description"] =~ @landobs_tag
      assert load_vector("proof-bundle-v6-negative.json")["description"] =~ @freq_tag
    end
  end

  defp vector_path(filename), do: Path.join(@vectors_dir, filename)

  # The value vector holds number text a float-based reader refuses (1e400),
  # so it is read with the grammar's own decoder.
  defp description("weather-value-landobs-v1.json" = file) do
    {:ok, v} = LandObsGrammar.decode(File.read!(vector_path(file)))
    v["description"]
  end

  defp description(file), do: load_vector(file)["description"]

  defp usec(%DateTime{} = dt), do: WallopCore.Time.to_rfc3339_usec(dt)

  defp landobs_state("a"), do: :weather
  defp landobs_state("b"), do: :frequency
  defp landobs_state("c"), do: :drand_only

  @receipt_timestamps ~w(locked_at weather_time freq_start executed_at weather_observation_time)

  # A receipt vector's `input` as builder input: atom keys, timestamps as DateTimes.
  defp atomize_receipt_input(map) do
    Map.new(map, fn {k, v} ->
      v = if k in @receipt_timestamps and is_binary(v), do: parse_datetime!(v), else: v
      {String.to_existing_atom(k), v}
    end)
  end

  defp assert_receipt_vector(v, file) do
    {builder, count, schema} =
      if Map.has_key?(v["input"], "locked_at"),
        do: {&Protocol.build_v6_lock_payload/1, 20, "6"},
        else: {&Protocol.build_v6_execution_payload/1, 28, "5"}

    payload = builder.(atomize_receipt_input(v["input"]))
    assert payload == v["payload_jcs"], file
    assert sha256_hex(payload) == v["expected_payload_sha256"], file
    assert v["expected_field_count"] == count, file
    assert v["expected_schema_version"] == schema, file
    assert map_size(Jason.decode!(payload)) == count, file
    assert Jason.decode!(payload)["schema_version"] == schema, file
  end

  # A positive bundle vector: its receipts are the receipt vectors', signed
  # by the vector keys, with no inline keys; the beacon is real; the seed is
  # the one the signed state calls for; the results and entropy follow.
  defp assert_bundle_vector(file, lock_file, exec_file, state) do
    v = load_vector(file)
    assert v["expected_passed"] == true, file
    bundle = Jason.decode!(v["bundle"])
    keys = keys_by_class(v["keys"])

    assert bundle["lock_receipt"]["payload_jcs"] == load_vector(lock_file)["payload_jcs"], file

    assert bundle["execution_receipt"]["payload_jcs"] == load_vector(exec_file)["payload_jcs"],
           file

    assert Map.keys(bundle["lock_receipt"]) == ["payload_jcs", "signature_hex"], file
    assert Map.keys(bundle["execution_receipt"]) == ["payload_jcs", "signature_hex"], file
    assert_signed(bundle, keys, file)

    lock = Jason.decode!(bundle["lock_receipt"]["payload_jcs"])
    exec = Jason.decode!(bundle["execution_receipt"]["payload_jcs"])
    assert exec["lock_receipt_hash"] == sha256_hex(bundle["lock_receipt"]["payload_jcs"]), file
    assert_real_beacon(bundle["entropy"], file)
    assert bundle["entropy"]["drand_round"] == exec["drand_round"], file
    assert bundle["entropy"]["drand_randomness"] == exec["drand_randomness"], file
    assert bundle["entropy"]["drand_signature"] == exec["drand_signature"], file

    for k <- ["weather_value", "freq_value"] do
      assert Map.get(bundle["entropy"], k) == exec[k], "#{file} #{k}"
    end

    {seed, _} =
      case {state, exec["freq_value"]} do
        {"a", _} ->
          Protocol.compute_seed(
            exec["entry_hash"],
            exec["drand_randomness"],
            exec["weather_value"]
          )

        {_, nil} ->
          Protocol.compute_seed(exec["entry_hash"], exec["drand_randomness"])

        {_, freq} ->
          Protocol.compute_freq_seed(exec["entry_hash"], exec["drand_randomness"], freq)
      end

    assert exec["seed"] == Base.encode16(seed, case: :lower), file

    entries = Enum.map(bundle["entries"], &%{uuid: &1["uuid"], weight: &1["weight"]})
    {entry_hash, _} = Protocol.entry_hash({bundle["draw_id"], entries})
    assert entry_hash == lock["entry_hash"], file
    winners = FairPick.draw(Enum.map(entries, &%{id: &1.uuid, weight: &1.weight}), seed, 2)
    assert exec["results"] == Enum.map(winners, & &1.entry_id), file

    assert bundle["results"] ==
             Enum.map(winners, &%{"entry_id" => &1.entry_id, "position" => &1.position}),
           file

    {:ok, locked_at, 0} = DateTime.from_iso8601(lock["locked_at"])
    {:ok, executed_at, 0} = DateTime.from_iso8601(exec["executed_at"])
    published = Quicknet.pub_time(lock["drand_round"])
    assert DateTime.compare(published, locked_at) == :gt, file
    assert DateTime.compare(executed_at, published) != :lt, file
  end

  defp keys_by_class(keys) do
    Map.new(keys, fn k ->
      {k["key_class"], {k["key_id"], Base.decode16!(k["public_key_hex"], case: :lower)}}
    end)
  end

  defp assert_signed(bundle, keys, name) do
    for {wrapper, class} <- [
          {"lock_receipt", "operator"},
          {"execution_receipt", "infrastructure"}
        ] do
      %{"payload_jcs" => jcs, "signature_hex" => sig} = bundle[wrapper]
      {kid, public} = Map.fetch!(keys, class)
      assert Jason.decode!(jcs)["signing_key_id"] == kid, "#{name} #{wrapper}"

      assert Protocol.verify_receipt(jcs, Base.decode16!(sig, case: :lower), public),
             "#{name} #{wrapper}"
    end
  end

  # quicknet randomness is SHA-256 of the signature.
  defp assert_real_beacon(entropy, name) do
    assert entropy["drand_chain_hash"] == Quicknet.chain_hash(), name

    assert sha256_hex(Base.decode16!(entropy["drand_signature"], case: :lower)) ==
             entropy["drand_randomness"],
           name
  end
end
