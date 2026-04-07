defmodule WallopCore.Resources.Draw.Changes.BroadcastUpdate do
  @moduledoc """
  Broadcasts `{:draw_updated, draw}` on PubSub after a successful action.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draw ->
      WallopCore.DrawPubSub.broadcast(draw)
      {:ok, draw}
    end)
  end
end
