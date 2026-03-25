defmodule Mix.Tasks.Wallop.Deactivate.ApiKey do
  use Mix.Task

  @shortdoc "Deactivate an API key by prefix"
  @moduledoc @shortdoc

  @impl true
  def run([prefix | _]) do
    Mix.Task.run("app.start")

    case WallopCore.Resources.ApiKey
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter_input(%{key_prefix: prefix})
         |> Ash.read_one(domain: WallopCore.Domain) do
      {:ok, nil} ->
        Mix.shell().error("No API key found with prefix: #{prefix}")

      {:ok, api_key} ->
        {:ok, _} =
          api_key
          |> Ash.Changeset.for_update(:deactivate, %{})
          |> Ash.update(domain: WallopCore.Domain)

        Mix.shell().info("API key #{prefix} (#{api_key.name}) deactivated.")

      {:error, error} ->
        Mix.shell().error("Error: #{inspect(error)}")
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.deactivate.api_key <prefix>")
  end
end
