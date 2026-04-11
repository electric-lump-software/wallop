# Generates spec/vectors/proof-bundle.json from a deterministic test draw.
# Run with: MIX_ENV=test mix run apps/wallop_core/test/wallop_core/proof_bundle_generator.exs
#
# The output is the canonical proof bundle for a frozen test draw — used
# by all consumers (wallop-verify CLI, fair_pick_rs, wallop_rs) for
# integration testing. It MUST stay byte-identical with the live
# /proof/:id.json endpoint output (enforced by a controller test).

import WallopCore.TestHelpers

# Set up isolated DB sandbox for the script
Ecto.Adapters.SQL.Sandbox.checkout(WallopCore.Repo)
Ecto.Adapters.SQL.Sandbox.mode(WallopCore.Repo, {:shared, self()})

_infra_key = create_infrastructure_key()
operator = create_operator("frozen-bundle-operator", "Frozen Bundle Operator")
api_key = create_api_key_for_operator(operator, "frozen-bundle-key")
draw = create_draw(api_key)
executed = execute_draw(draw, test_seed(), api_key)

{:ok, bundle_json} = WallopCore.ProofBundle.build(executed)

output_path = Path.expand("../../../../spec/vectors/proof-bundle.json", __DIR__)
File.write!(output_path, bundle_json)

IO.puts("Wrote #{byte_size(bundle_json)} bytes to #{output_path}")
