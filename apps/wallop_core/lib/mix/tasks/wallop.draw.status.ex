defmodule Mix.Tasks.Wallop.Draw.Status do
  @moduledoc """
  Show the status of a draw.

  ## Usage

      mix wallop.draw.status DRAW_ID
  """
  use Mix.Task

  @shortdoc "Show draw status"

  def run([draw_id | _]) do
    Mix.Task.run("app.start")

    draw = load_draw(draw_id)

    IO.puts("""

    Draw #{draw.id}:

      Status:        #{draw.status}
      Entries:       #{length(draw.entries || [])}
      Winner count:  #{draw.winner_count}
      Entry hash:    #{draw.entry_hash || "(not locked)"}
      Weather time:  #{draw.weather_time || "(not declared)"}
      Executed at:   #{draw.executed_at || "(pending)"}
      Timestamps:    #{inspect(draw.stage_timestamps)}
    """)

    if draw.results do
      IO.puts("  Results:")

      Enum.each(draw.results, fn r ->
        IO.puts("    #{r["position"]}. #{r["entry_id"]}")
      end)

      IO.puts("")
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.draw.status DRAW_ID")
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
