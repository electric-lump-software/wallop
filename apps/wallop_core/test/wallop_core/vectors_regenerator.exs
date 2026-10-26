# Regenerates the schema 4 lock receipt vectors.
# Run with: MIX_ENV=test mix run apps/wallop_core/test/wallop_core/vectors_regenerator.exs
#
# Updates (in place):
#   spec/vectors/lock-receipt.json
#   spec/vectors/cross-receipt-linkage.json
#
# Each input is kept verbatim except `drand_round`, which is set to a real
# quicknet round published after the input's `locked_at`. Only the
# `expected_*` fields are recomputed. Description text is kept.
#
# There is no schema 4 lock builder (`Protocol.build_receipt_payload/1`
# emits schema 5). The field sets are identical, so the schema 4 bytes are
# the schema 5 builder's output with `schema_version` set back to "4".
#
# The schema 2 execution receipt vectors (`execution-receipt.json`,
# `execution-receipt-drand-only.json`) have no builder at all. They are
# frozen fossils and this script does not touch them.
#
# Run this before `vectors_regenerator_v5.exs`, which copies these inputs
# into the schema 5 vectors.

alias WallopCore.Protocol

vectors_dir = Path.expand("../../../../spec/vectors", __DIR__)

# Real quicknet rounds, each published after its vector's locked_at:
#   27587802: 2026-04-07T12:59:30Z (lock-receipt.json, locked 12:34:56.789012Z)
#   27644402: 2026-04-09T12:09:30Z (cross-receipt-linkage.json, locked 12:00:00Z)
rounds = %{"lock-receipt.json" => 27_587_802, "cross-receipt-linkage.json" => 27_644_402}

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

schema_4_payload = fn input_map ->
  input_map
  |> to_lock_input.()
  |> Protocol.build_receipt_payload()
  |> Jason.decode!()
  |> Map.put("schema_version", "4")
  |> Jcs.encode()
end

published_after_lock! = fn input_map, file ->
  {:ok, locked_at, 0} = DateTime.from_iso8601(input_map["locked_at"])
  published = WallopCore.Drand.Quicknet.pub_time(input_map["drand_round"])

  unless DateTime.compare(published, locked_at) == :gt,
    do: raise("#{file}: round #{input_map["drand_round"]} is published before locked_at")
end

write_json = fn path, data ->
  File.write!(path, Jason.encode_to_iodata!(data, pretty: true) |> IO.iodata_to_binary())
  IO.puts("Wrote #{path}")
end

# --- lock-receipt.json (schema 4) ---
lock_path = Path.join(vectors_dir, "lock-receipt.json")
lock = lock_path |> File.read!() |> Jason.decode!()
lock_input = Map.put(lock["input"], "drand_round", rounds["lock-receipt.json"])
published_after_lock!.(lock_input, "lock-receipt.json")
lock_payload = schema_4_payload.(lock_input)
lock_decoded = Jason.decode!(lock_payload)

lock
|> Map.put("input", lock_input)
|> Map.put("expected_payload_sha256", sha256_hex.(lock_payload))
|> Map.put("expected_field_count", map_size(lock_decoded))
|> Map.put("expected_schema_version", lock_decoded["schema_version"])
|> then(&write_json.(lock_path, &1))

# --- cross-receipt-linkage.json (schema 4 lock) ---
linkage_path = Path.join(vectors_dir, "cross-receipt-linkage.json")
linkage = linkage_path |> File.read!() |> Jason.decode!()

linkage_input =
  Map.put(linkage["lock_receipt_input"], "drand_round", rounds["cross-receipt-linkage.json"])

published_after_lock!.(linkage_input, "cross-receipt-linkage.json")

linkage
|> Map.put("lock_receipt_input", linkage_input)
|> Map.put("expected_lock_payload_sha256", sha256_hex.(schema_4_payload.(linkage_input)))
|> then(&write_json.(linkage_path, &1))

IO.puts("\nDone. Run vectors_regenerator_v5.exs next, then mix test.")
