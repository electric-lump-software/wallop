# Regenerates the receipt-shape frozen vectors after a schema bump.
# Run with: MIX_ENV=test mix run apps/wallop_core/test/wallop_core/vectors_regenerator.exs
#
# Updates (in place):
#   spec/vectors/lock-receipt.json
#   spec/vectors/execution-receipt.json
#   spec/vectors/execution-receipt-drand-only.json
#   spec/vectors/cross-receipt-linkage.json
#
# The `input` sections are preserved verbatim — only the `expected_*`
# fields are recomputed against the current Protocol.build_*_payload
# functions. Description text is also kept.

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
    executed_at: parse_dt.(map["executed_at"])
  }
end

write_json = fn path, data ->
  File.write!(path, Jason.encode_to_iodata!(data, pretty: true) |> IO.iodata_to_binary())
  IO.puts("Wrote #{path}")
end

# --- lock-receipt.json ---
lock_path = Path.join(vectors_dir, "lock-receipt.json")
lock = lock_path |> File.read!() |> Jason.decode!()
lock_input = to_lock_input.(lock["input"])
lock_payload = Protocol.build_receipt_payload(lock_input)
lock_decoded = Jason.decode!(lock_payload)

lock
|> Map.put("expected_payload_sha256", sha256_hex.(lock_payload))
|> Map.put("expected_field_count", map_size(lock_decoded))
|> Map.put("expected_schema_version", lock_decoded["schema_version"])
|> then(&write_json.(lock_path, &1))

# --- execution-receipt.json ---
exec_path = Path.join(vectors_dir, "execution-receipt.json")
exec = exec_path |> File.read!() |> Jason.decode!()

# Rewrite weather_fallback_reason in input if it's a stale string.
valid? = fn v -> v in ["station_down", "stale", "unreachable", nil] end

exec_input_map =
  if valid?.(Map.get(exec["input"], "weather_fallback_reason")) do
    exec["input"]
  else
    Map.put(exec["input"], "weather_fallback_reason", nil)
  end

exec_input = to_exec_input.(exec_input_map)
exec_payload = Protocol.build_execution_receipt_payload(exec_input)
exec_decoded = Jason.decode!(exec_payload)

exec
|> Map.put("input", exec_input_map)
|> Map.put("expected_payload_sha256", sha256_hex.(exec_payload))
|> Map.put("expected_field_count", map_size(exec_decoded))
|> Map.put("expected_schema_version", exec_decoded["schema_version"])
|> Map.delete("expected_execution_schema_version")
|> then(&write_json.(exec_path, &1))

# --- execution-receipt-drand-only.json ---
drand_only_path = Path.join(vectors_dir, "execution-receipt-drand-only.json")
drand_only = drand_only_path |> File.read!() |> Jason.decode!()

drand_only_input_map =
  if valid?.(Map.get(drand_only["input"], "weather_fallback_reason")) do
    drand_only["input"]
  else
    Map.put(drand_only["input"], "weather_fallback_reason", "unreachable")
  end

drand_only_input = to_exec_input.(drand_only_input_map)
drand_only_payload = Protocol.build_execution_receipt_payload(drand_only_input)

drand_only
|> Map.put("input", drand_only_input_map)
|> Map.put("expected_payload_sha256", sha256_hex.(drand_only_payload))
|> then(&write_json.(drand_only_path, &1))

# --- cross-receipt-linkage.json ---
linkage_path = Path.join(vectors_dir, "cross-receipt-linkage.json")
linkage = linkage_path |> File.read!() |> Jason.decode!()
linkage_input = to_lock_input.(linkage["lock_receipt_input"])
linkage_payload = Protocol.build_receipt_payload(linkage_input)

linkage
|> Map.put("expected_lock_payload_sha256", sha256_hex.(linkage_payload))
|> then(&write_json.(linkage_path, &1))

IO.puts("\nDone. Re-run mix test to verify.")
