defmodule Mix.Tasks.Wallop.Draw.AddEntries do
  @moduledoc """
  Add entries to an open draw.

  ## Usage

      mix wallop.draw.add_entries API_KEY DRAW_ID ENTRY_IDS...

  ## Example

      mix wallop.draw.add_entries "wallop_abc123..." "uuid-here" alice bob charlie

  All entries are added with weight 1.
  """
  use Mix.Task

  @shortdoc "Add entries to an open draw"

  def run([key, draw_id | entry_ids]) when entry_ids != [] do
    Mix.Task.run("app.start")

    api_key = find_api_key(key)
    draw = load_draw(draw_id)

    entries = Enum.map(entry_ids, fn id -> %{"id" => id, "weight" => 1} end)

    updated =
      draw
      |> Ash.Changeset.for_update(:add_entries, %{entries: entries}, actor: api_key)
      |> Ash.update!()

    IO.puts("""

    Entries added to draw #{draw_id}:

      Added:  #{Enum.join(entry_ids, ", ")}
      Total:  #{length(updated.entries)} entries
      Status: #{updated.status}

    Note: mix tasks run in a separate process. The proof page will
    update within 30 seconds via polling, or instantly via HTTP API.
    """)
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.draw.add_entries API_KEY DRAW_ID ENTRY_IDS...")
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
