defmodule WallopCore.DrawPubSub do
  @moduledoc """
  Centralised PubSub broadcaster for Draw lifecycle events.

  Every change that updates a draw (create, add_entries, lock, execute,
  expire, mark_failed, etc) calls `broadcast/1` to push a `{:draw_updated,
  draw}` message to two topics:

  * `draw:<id>` — the proof page subscribes to this for live updates on a
    single draw
  * `operator:<operator_id>` — the operator's public registry page subscribes
    to this for live updates as new draws appear and existing ones change
    state. Skipped when the draw has no operator (backward compatible).
  """

  @spec broadcast(map()) :: :ok | {:error, term()}
  def broadcast(draw) do
    Phoenix.PubSub.broadcast(
      WallopCore.PubSub,
      "draw:#{draw.id}",
      {:draw_updated, draw}
    )

    if Map.get(draw, :operator_id) do
      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "operator:#{draw.operator_id}",
        {:draw_updated, draw}
      )
    end

    :ok
  end
end
