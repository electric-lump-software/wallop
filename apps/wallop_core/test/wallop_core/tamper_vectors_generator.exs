# Generates the tamper vectors, one file per entropy tag:
# spec/vectors/proof-bundle-v6-tamper.json (Land Observations) and
# spec/vectors/proof-bundle-v6-tamper-freq.json (grid frequency). Run with:
#
#   MIX_ENV=test mix run apps/wallop_core/test/wallop_core/tamper_vectors_generator.exs
#
# The bundles are built by WallopCore.TamperVectors (test/support) from the
# real lock v6 / execution v5 builders and each tag's
# WallopCore.TamperProfiles module; see its moduledoc for the format.
# Generation is deterministic, and TamperTest checks each committed file
# equals the module's output.

alias WallopCore.TamperVectors

for profile <- TamperVectors.profiles() do
  bytes = TamperVectors.encode(profile)
  File.write!(TamperVectors.path(profile), bytes)
  IO.puts("Wrote #{byte_size(bytes)} bytes to #{TamperVectors.path(profile)}")
end
