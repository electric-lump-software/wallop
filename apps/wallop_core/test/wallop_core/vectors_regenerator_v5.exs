# Generates the v5 lock-receipt and v4 execution-receipt frozen vectors
# alongside the existing v4 / v3 / v2 fossils. Run with:
#
#   MIX_ENV=test mix run apps/wallop_core/test/wallop_core/vectors_regenerator_v5.exs
#
# Reads inputs verbatim from the existing v4 / v3 vector files, runs them
# through the (bumped) Protocol builders, and writes new files:
#
#   spec/vectors/lock-receipt-v5.json
#   spec/vectors/execution-receipt-v4.json
#   spec/vectors/execution-receipt-drand-only-v4.json
#
# Existing vector files (lock-receipt.json @ v4, execution-receipt-v3.json
# @ v3, execution-receipt-drand-only-v3.json @ v3, execution-receipt.json
# @ v2, execution-receipt-drand-only.json @ v2) are NOT touched. Once
# pinned, frozen vectors are immutable — they are the historical record
# for cross-language verifier regression.

alias WallopCore.Protocol

vectors_dir = Path.expand("../../../../spec/vectors", __DIR__)

sha256_hex = fn bin ->
  :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end

parse_dt = fn
  nil ->
    nil

  bin when is_binary(bin) ->
    {:ok, dt, _} = DateTime.from_iso8601(bin)
    dt
end

to_lock_input = fn map ->
  %{
    operator_id: map["operator_id"],
    operator_slug: map["operator_slug"],
    sequence: map["sequence"],
    draw_id: map["draw_id"],
    commitment_hash: map["commitment_hash"],
    entry_hash: map["entry_hash"],
    locked_at: parse_dt.(map["locked_at"]),
    signing_key_id: map["signing_key_id"],
    winner_count: map["winner_count"],
    drand_chain: map["drand_chain"],
    drand_round: map["drand_round"],
    weather_station: map["weather_station"],
    weather_time: parse_dt.(map["weather_time"]),
    wallop_core_version: map["wallop_core_version"],
    fair_pick_version: map["fair_pick_version"]
  }
end

to_exec_input = fn map ->
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
    weather_observation_time: parse_dt.(map["weather_observation_time"]),
    weather_value: map["weather_value"],
    weather_fallback_reason: map["weather_fallback_reason"],
    wallop_core_version: map["wallop_core_version"],
    fair_pick_version: map["fair_pick_version"],
    seed: map["seed"],
    results: map["results"],
    executed_at: parse_dt.(map["executed_at"]),
    signing_key_id: map["signing_key_id"]
  }
end

write_json = fn path, data ->
  File.write!(path, Jason.encode_to_iodata!(data, pretty: true) |> IO.iodata_to_binary())
  IO.puts("Wrote #{path}")
end

# --- lock-receipt-v5.json ---
v4_path = Path.join(vectors_dir, "lock-receipt.json")
v5_path = Path.join(vectors_dir, "lock-receipt-v5.json")
v4 = v4_path |> File.read!() |> Jason.decode!()
v5_input = to_lock_input.(v4["input"])
v5_payload = Protocol.build_receipt_payload(v5_input)
v5_decoded = Jason.decode!(v5_payload)

%{
  "description" =>
    "Lock receipt JCS payload (schema v5) — byte-identical field set to v4; " <>
      "schema_version is the only difference. Producers MUST omit " <>
      "operator_public_key_hex from the bundle wrapper (resolver-driven verification).",
  "expected_field_count" => map_size(v5_decoded),
  "expected_payload_sha256" => sha256_hex.(v5_payload),
  "expected_schema_version" => v5_decoded["schema_version"],
  "input" => v4["input"]
}
|> then(&write_json.(v5_path, &1))

# --- execution-receipt-v4.json ---
v3_exec_path = Path.join(vectors_dir, "execution-receipt-v3.json")
v4_exec_path = Path.join(vectors_dir, "execution-receipt-v4.json")
v3_exec = v3_exec_path |> File.read!() |> Jason.decode!()
v4_exec_input = to_exec_input.(v3_exec["input"])
v4_exec_payload = Protocol.build_execution_receipt_payload(v4_exec_input)
v4_exec_decoded = Jason.decode!(v4_exec_payload)

%{
  "description" =>
    "Execution receipt JCS payload (schema v4) — byte-identical field set to v3; " <>
      "schema_version is the only difference. Producers MUST omit " <>
      "infrastructure_public_key_hex from the bundle wrapper.",
  "expected_field_count" => map_size(v4_exec_decoded),
  "expected_payload_sha256" => sha256_hex.(v4_exec_payload),
  "expected_schema_version" => v4_exec_decoded["schema_version"],
  "input" => v3_exec["input"]
}
|> then(&write_json.(v4_exec_path, &1))

# --- execution-receipt-drand-only-v4.json ---
v3_drand_path = Path.join(vectors_dir, "execution-receipt-drand-only-v3.json")
v4_drand_path = Path.join(vectors_dir, "execution-receipt-drand-only-v4.json")
v3_drand = v3_drand_path |> File.read!() |> Jason.decode!()
v4_drand_input = to_exec_input.(v3_drand["input"])
v4_drand_payload = Protocol.build_execution_receipt_payload(v4_drand_input)
v4_drand_decoded = Jason.decode!(v4_drand_payload)

%{
  "description" =>
    "Drand-only execution receipt JCS payload (schema v4) — byte-identical " <>
      "field set to v3; weather fields all null with weather_fallback_reason set.",
  "expected_field_count" => map_size(v4_drand_decoded),
  "expected_payload_sha256" => sha256_hex.(v4_drand_payload),
  "expected_schema_version" => v4_drand_decoded["schema_version"],
  "input" => v3_drand["input"]
}
|> then(&write_json.(v4_drand_path, &1))

# --- cross-receipt-linkage-v5.json ---
# v5 lock chained to v4 drand-only execution receipt. The v4 fossil
# (`cross-receipt-linkage.json`) stays on disk for the Rust verifier's
# v4 cross-receipt regression.
linkage_v4_path = Path.join(vectors_dir, "cross-receipt-linkage.json")
linkage_v5_path = Path.join(vectors_dir, "cross-receipt-linkage-v5.json")
linkage_v4 = linkage_v4_path |> File.read!() |> Jason.decode!()

linkage_lock_input = to_lock_input.(linkage_v4["lock_receipt_input"])
linkage_lock_payload = Protocol.build_receipt_payload(linkage_lock_input)
linkage_lock_sha = sha256_hex.(linkage_lock_payload)

%{
  "description" =>
    "Cross-receipt linkage at schema v5 lock + v4 execution. The lock " <>
      "receipt's SHA-256 is bound into the execution receipt's " <>
      "lock_receipt_hash field; verifiers reject any mismatch.",
  "lock_receipt_input" => linkage_v4["lock_receipt_input"],
  "expected_lock_payload_sha256" => linkage_lock_sha
}
|> then(&write_json.(linkage_v5_path, &1))

IO.puts("\nDone. Existing v4 / v3 / v2 vectors preserved verbatim.")
