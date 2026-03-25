defmodule Mix.Tasks.Wallop.List.ApiKeys do
  use Mix.Task

  @shortdoc "List all API keys"
  @moduledoc @shortdoc

  @impl true
  def run(_) do
    Mix.Task.run("app.start")

    {:ok, keys} =
      WallopCore.Resources.ApiKey
      |> Ash.Query.for_read(:read)
      |> Ash.read(domain: WallopCore.Domain)

    if Enum.empty?(keys) do
      Mix.shell().info("No API keys found.")
    else
      Mix.shell().info("\nAPI Keys:\n")
      Enum.each(keys, &print_key/1)
      Mix.shell().info("")
    end
  end

  defp print_key(key) do
    status = if key.active, do: "active", else: "inactive"
    Mix.shell().info("  #{key.key_prefix}  #{key.name}  [#{status}]  created #{key.inserted_at}")
  end
end
