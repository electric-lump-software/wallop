defmodule WallopCore.V5BuilderRegressionTest do
  @moduledoc """
  Builder regression: today's v5 receipt hashes, kept after the published
  vectors were regenerated with real drand rounds. Never regenerate these
  files.

  The fixtures in `test/fixtures/v5_builder_regression/` are byte copies of
  `spec/vectors/lock-receipt.json`, `lock-receipt-v5.json`,
  `cross-receipt-linkage.json` and `cross-receipt-linkage-v5.json` as they
  stood before the regeneration. The v4 files have no Elixir builder (it
  emits schema 5), so they are checked by swapping only `schema_version`
  back to "4" on the v5 builder's output: the field sets are identical.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  @fixtures_dir Path.expand("../fixtures/v5_builder_regression", __DIR__)

  defp load_vector(filename) do
    @fixtures_dir
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  @ed25519 Jason.decode!(
             File.read!(Path.expand("../../../../spec/vectors/ed25519.json", __DIR__))
           )
  @test_private_key Base.decode16!(@ed25519["keypair"]["private_key_hex"], case: :mixed)
  @test_public_key Base.decode16!(@ed25519["keypair"]["public_key_hex"], case: :mixed)

  # ── V-5: Lock receipt payload ─────────────────────────────────────

  describe "V-5: lock receipt payload (schema v5)" do
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

  # ── Schema 4 lock bytes ────────────────────────────────────────────

  describe "schema 4 lock bytes (v5 builder output with schema_version \"4\")" do
    test "lock-receipt.json" do
      v = load_vector("lock-receipt.json")
      assert v["expected_schema_version"] == "4"

      payload = as_schema_4(Protocol.build_receipt_payload(to_lock_input(v["input"])))

      assert sha256_hex(payload) == v["expected_payload_sha256"]
      assert payload |> Jason.decode!() |> map_size() == v["expected_field_count"]
    end

    test "cross-receipt-linkage.json" do
      v = load_vector("cross-receipt-linkage.json")
      payload = Protocol.build_receipt_payload(to_lock_input(v["lock_receipt_input"]))

      assert sha256_hex(as_schema_4(payload)) == v["expected_lock_payload_sha256"]
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp as_schema_4(payload) do
    payload |> Jason.decode!() |> Map.put("schema_version", "4") |> Jcs.encode()
  end

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

  defp parse_datetime!(str), do: DateTime.from_iso8601(str) |> elem(1)
  defp parse_datetime(nil), do: nil
  defp parse_datetime(str), do: parse_datetime!(str)
end
