defmodule WallopCore.Resources.Draw.Changes.RemoveEntry do
  @moduledoc """
  Removes a single entry from an open draw by entry ID.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    draw = changeset.data
    entry_id = Ash.Changeset.get_argument(changeset, :entry_id)

    existing = draw.entries || []
    {removed, remaining} = Enum.split_with(existing, fn e -> (e["id"] || e[:id]) == entry_id end)

    if removed == [] do
      Ash.Changeset.add_error(changeset, field: :entry_id, message: "entry not found")
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:entries, remaining)
      |> Ash.Changeset.after_action(fn _changeset, draw ->
        Phoenix.PubSub.broadcast(WallopWeb.PubSub, "draw:#{draw.id}", {:draw_updated, draw})
        {:ok, draw}
      end)
    end
  end
end
