defmodule WallopCore.Resources.Draw.Changes.BroadcastUpdate do
  @moduledoc """
  Broadcasts `{:draw_updated, draw}` on PubSub once the action's transaction
  has committed. A transition that rolls back is never announced.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, draw} ->
        WallopCore.DrawPubSub.broadcast(draw)
        {:ok, draw}

      _changeset, error ->
        error
    end)
  end
end
