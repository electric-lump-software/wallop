# Seeds for development
# Run: mix run apps/wallop_core/priv/repo/seeds.exs

IO.puts("\nCreating development API key...\n")
Mix.Task.run("wallop.gen.api_key", ["Development"])
