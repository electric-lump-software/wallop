defmodule Mix.Tasks.Wallop.Draw.Lock do
  @moduledoc """
  Lock an open draw — freezes entries, declares entropy, starts countdown.

  ## Usage

      mix wallop.draw.lock API_KEY DRAW_ID

  ## Example

      mix wallop.draw.lock "wallop_abc123..." "uuid-here"
  """
  use Mix.Task

  @shortdoc "Lock a draw and start entropy collection"

  def run([key, draw_id | _]) do
    Mix.Task.run("app.start")

    api_key = find_api_key(key)
    draw = load_draw(draw_id)

    locked =
      draw
      |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
      |> Ash.update!()

    IO.puts("""

    Draw locked:

      ID:           #{locked.id}
      Status:       #{locked.status}
      Entries:      #{length(locked.entries)}
      Entry hash:   #{locked.entry_hash}
      Weather time: #{locked.weather_time}
      Proof page:   /proof/#{locked.id}
    """)
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.draw.lock API_KEY DRAW_ID")
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

  defp load_draw(id) do
    case Ash.get(WallopCore.Resources.Draw, id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, draw} -> draw
      _ -> Mix.raise("Draw #{id} not found")
    end
  end
end
