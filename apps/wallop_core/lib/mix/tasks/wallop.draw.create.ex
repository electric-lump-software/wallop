defmodule Mix.Tasks.Wallop.Draw.Create do
  @moduledoc """
  Create a new open draw.

  ## Usage

      mix wallop.draw.create API_KEY WINNER_COUNT

  ## Example

      mix wallop.draw.create "wallop_abc123..." 2
  """
  use Mix.Task

  @shortdoc "Create a new open draw"

  def run([key, winner_count_str | _]) do
    Mix.Task.run("app.start")

    winner_count = String.to_integer(winner_count_str)
    api_key = find_api_key(key)

    draw =
      WallopCore.Resources.Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: winner_count}, actor: api_key)
      |> Ash.create!()

    IO.puts("""

    Draw created:

      ID:           #{draw.id}
      Status:       #{draw.status}
      Winner count: #{draw.winner_count}
      Proof page:   /proof/#{draw.id}

    Note: mix tasks run in a separate process. The proof page will
    update within 30 seconds via polling, or instantly via HTTP API.
    """)
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.draw.create API_KEY WINNER_COUNT")
  end

  defp find_api_key(key) do
    require Ash.Query

    WallopCore.Resources.ApiKey
    |> Ash.Query.filter(active == true)
    |> Ash.read!(domain: WallopCore.Domain, authorize?: false)
    |> Enum.find(fn ak -> Bcrypt.verify_pass(key, ak.key_hash) end)
    |> case do
      nil -> Mix.raise("API key not found or inactive")
      api_key -> api_key
    end
  end
end
