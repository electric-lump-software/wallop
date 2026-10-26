# Generates spec/vectors/proof-bundle*.json: lock 5 / execution 4 proof
# bundles for fixed draws. Run with:
#
#   MIX_ENV=test mix run apps/wallop_core/test/wallop_core/proof_bundle_generator.exs
#
# Output:
# - spec/vectors/proof-bundle.json: drand + weather
# - spec/vectors/proof-bundle-drand-only.json: drand only (no weather_value)
#
# Pure: no database. The receipts come from the live builders
# (`Protocol.build_receipt_payload/1`, `Protocol.build_execution_receipt_payload/1`),
# the bundle from `WallopCore.ProofBundle.assemble/1`, which the live
# `/proof/:id.json` endpoint also uses. Both receipts are signed with the
# deterministic vector keys (`WallopCore.TamperVectors`). Lock 5 / execution 4
# bundles carry no inline keys: verifiers resolve the keys by `signing_key_id`.
#
# The drand round is real: quicknet round 33068202, published
# 2026-10-14T19:59:30Z, after `locked_at`. The weather value is not a real
# reading.

alias WallopCore.Drand.Quicknet
alias WallopCore.Protocol
alias WallopCore.TamperVectors, as: Keys

vectors_dir = Path.expand("../../../../spec/vectors", __DIR__)

round = 33_068_202
randomness = "af201a914afbee053f376e6f483e7fe9c5989c0d718d9dae74bf46ebb11aaeff"

signature =
  "a5725b4bf6958d6e64f7922cf6ab7cbfe128ec205e6fbd2c57ffc47cc9861d837223d98d7d8c18c46f2bbe1ab55581ca"

locked_at = ~U[2026-10-14 19:55:00.000000Z]
weather_time = ~U[2026-10-14 20:00:00.000000Z]
executed_at = ~U[2026-10-14 20:00:05.000000Z]
winner_count = 2

# quicknet randomness is SHA-256 of the signature; the round publishes after
# the lock and no later than execution.
true =
  :crypto.hash(:sha256, Base.decode16!(signature, case: :lower)) |> Base.encode16(case: :lower) ==
    randomness

true = DateTime.compare(Quicknet.pub_time(round), locked_at) == :gt
true = DateTime.compare(executed_at, Quicknet.pub_time(round)) != :lt

{op_sk, _op_pub, op_kid} = Keys.operator_key()
{infra_sk, _infra_pub, infra_kid} = Keys.infrastructure_key()

sha256_hex = fn bin -> :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower) end

bundle = fn draw_id, slug, weather ->
  entries =
    for n <- 1..5, do: %{uuid: "00000000-0000-4000-8000-00000000000#{n}", weight: 1}

  {entry_hash, _} = Protocol.entry_hash({draw_id, entries})

  lock_jcs =
    Protocol.build_receipt_payload(%{
      operator_id: "11111111-1111-4111-8111-111111111111",
      operator_slug: slug,
      sequence: 1,
      draw_id: draw_id,
      commitment_hash: entry_hash,
      entry_hash: entry_hash,
      locked_at: locked_at,
      signing_key_id: op_kid,
      winner_count: winner_count,
      drand_chain: Quicknet.chain_hash(),
      drand_round: round,
      weather_station: "middle-wallop",
      weather_time: weather_time,
      wallop_core_version: "0.29.0",
      fair_pick_version: Keys.fair_pick_version()
    })

  {seed, {weather_value, observed_at, reason}} =
    case weather do
      nil ->
        {seed, _} = Protocol.compute_seed(entry_hash, randomness)
        {seed, {nil, nil, "unreachable"}}

      value ->
        {seed, _} = Protocol.compute_seed(entry_hash, randomness, value)
        {seed, {value, weather_time, nil}}
    end

  winners = FairPick.draw(Enum.map(entries, &%{id: &1.uuid, weight: 1}), seed, winner_count)

  exec_jcs =
    Protocol.build_execution_receipt_payload(%{
      draw_id: draw_id,
      operator_id: "11111111-1111-4111-8111-111111111111",
      operator_slug: slug,
      sequence: 1,
      lock_receipt_hash: sha256_hex.(lock_jcs),
      entry_hash: entry_hash,
      drand_chain: Quicknet.chain_hash(),
      drand_round: round,
      drand_randomness: randomness,
      drand_signature: signature,
      weather_station: "middle-wallop",
      weather_observation_time: observed_at,
      weather_value: weather_value,
      weather_fallback_reason: reason,
      wallop_core_version: "0.29.0",
      fair_pick_version: Keys.fair_pick_version(),
      seed: Base.encode16(seed, case: :lower),
      results: Enum.map(winners, & &1.entry_id),
      executed_at: executed_at,
      signing_key_id: infra_kid
    })

  entropy =
    %{
      "drand_round" => round,
      "drand_randomness" => randomness,
      "drand_signature" => signature,
      "drand_chain_hash" => Quicknet.chain_hash()
    }
    |> then(&if(weather_value, do: Map.put(&1, "weather_value", weather_value), else: &1))

  WallopCore.ProofBundle.assemble(%{
    draw_id: draw_id,
    entries: Enum.map(entries, &%{"uuid" => &1.uuid, "weight" => &1.weight}),
    results: Enum.map(winners, &%{"entry_id" => &1.entry_id, "position" => &1.position}),
    entropy: entropy,
    lock_receipt: {lock_jcs, Protocol.sign_receipt(lock_jcs, op_sk)},
    execution_receipt: {exec_jcs, Protocol.sign_receipt(exec_jcs, infra_sk)},
    inline_keys: %{lock: nil, exec: nil}
  })
end

for {file, draw_id, slug, weather} <- [
      {"proof-bundle.json", "55555555-5555-4555-8555-555555555551", "frozen-bundle-operator",
       "102340"},
      {"proof-bundle-drand-only.json", "55555555-5555-4555-8555-555555555552",
       "frozen-bundle-operator-drand-only", nil}
    ] do
  json = bundle.(draw_id, slug, weather)
  path = Path.join(vectors_dir, file)
  File.write!(path, json)
  IO.puts("Wrote #{byte_size(json)} bytes to #{path}")
end
