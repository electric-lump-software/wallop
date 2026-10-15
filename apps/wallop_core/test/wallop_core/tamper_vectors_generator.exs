# Generates spec/vectors/proof-bundle-v6-tamper.json. Run with:
#
#   MIX_ENV=test mix run apps/wallop_core/test/wallop_core/tamper_vectors_generator.exs
#
# The bundles are built by WallopCore.TamperVectors (test/support) from the
# real lock v6 / execution v5 builders; see its moduledoc for the format.
# Generation is deterministic, and TamperVectorsTest checks the committed
# file equals the module's output.

alias WallopCore.TamperVectors

bytes = TamperVectors.encode()
File.write!(TamperVectors.path(), bytes)
IO.puts("Wrote #{byte_size(bytes)} bytes to #{TamperVectors.path()}")
