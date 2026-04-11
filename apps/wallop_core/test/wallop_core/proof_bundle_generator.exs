# Generates spec/vectors/proof-bundle*.json from deterministic test draws.
# Run with: MIX_ENV=test mix run apps/wallop_core/test/wallop_core/proof_bundle_generator.exs
#
# Output:
# - spec/vectors/proof-bundle.json — drand + weather variant
# - spec/vectors/proof-bundle-drand-only.json — drand-only variant (no weather_value)
#
# Both are canonical proof bundles for frozen test draws — used by
# all consumers (wallop-verify CLI, fair_pick_rs, wallop_verifier) for
# integration testing. They MUST stay byte-identical with the live
# /proof/:id.json endpoint output (enforced by a controller test).

import WallopCore.TestHelpers

# Set up isolated DB sandbox for the script
Ecto.Adapters.SQL.Sandbox.checkout(WallopCore.Repo)
Ecto.Adapters.SQL.Sandbox.mode(WallopCore.Repo, {:shared, self()})

_infra_key = create_infrastructure_key()

# Variant 1: drand + weather
operator_a = create_operator("frozen-bundle-operator", "Frozen Bundle Operator")
api_key_a = create_api_key_for_operator(operator_a, "frozen-bundle-key")
draw_a = create_draw(api_key_a)
executed_a = execute_draw(draw_a, test_seed(), api_key_a)

{:ok, bundle_json} = WallopCore.ProofBundle.build(executed_a)

output_path = Path.expand("../../../../spec/vectors/proof-bundle.json", __DIR__)
File.write!(output_path, bundle_json)
IO.puts("Wrote #{byte_size(bundle_json)} bytes to #{output_path}")

# Variant 2: drand-only (weather unavailable, weather_value omitted entirely)
operator_b =
  create_operator("frozen-bundle-operator-drand-only", "Frozen Bundle Operator (Drand-only)")

api_key_b = create_api_key_for_operator(operator_b, "frozen-bundle-key-drand-only")
draw_b = create_draw(api_key_b)

executed_b =
  draw_b
  |> Ash.Changeset.for_update(:transition_to_pending, %{})
  |> Ash.update!(domain: WallopCore.Domain, authorize?: false)
  |> Ash.Changeset.for_update(:execute_drand_only, %{
    drand_randomness: test_drand_randomness(),
    drand_signature: "test-signature",
    drand_response: "{}",
    weather_fallback_reason: "frozen vector — weather unavailable"
  })
  |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

{:ok, drand_only_json} = WallopCore.ProofBundle.build(executed_b)

drand_only_path = Path.expand("../../../../spec/vectors/proof-bundle-drand-only.json", __DIR__)
File.write!(drand_only_path, drand_only_json)
IO.puts("Wrote #{byte_size(drand_only_json)} bytes to #{drand_only_path}")
