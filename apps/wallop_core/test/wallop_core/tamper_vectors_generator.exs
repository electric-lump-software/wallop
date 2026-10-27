alias WallopCore.TamperVectors

for profile <- TamperVectors.profiles() do
  bytes = TamperVectors.encode(profile)
  File.write!(TamperVectors.path(profile), bytes)
  IO.puts("Wrote #{byte_size(bytes)} bytes to #{TamperVectors.path(profile)}")
end
