defmodule WallopCore.Resources.Draw.Changes.RemoveEntry do
  @moduledoc """
  Removes a single entry from an open draw by its wallop-assigned UUID
  (the Entry's `id` — the public identifier bound into `entry_hash`).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias WallopCore.Resources.Entry

  @impl true
  def change(changeset, _opts, _context) do
    draw = changeset.data
    entry_uuid = Ash.Changeset.get_argument(changeset, :entry_uuid)

    case find_entry(draw.id, entry_uuid) do
      nil ->
        Ash.Changeset.add_error(changeset, field: :entry_uuid, message: "entry not found")

      entry ->
        new_count = max((draw.entry_count || 0) - 1, 0)

        changeset
        |> Ash.Changeset.force_change_attribute(:entry_count, new_count)
        |> Ash.Changeset.after_action(fn _changeset, draw ->
          Ash.destroy!(entry, authorize?: false)
          WallopCore.DrawPubSub.broadcast(draw)
          {:ok, draw}
        end)
    end
  end

  defp find_entry(draw_id, entry_uuid) do
    Entry
    |> Ash.Query.filter(draw_id == ^draw_id and id == ^entry_uuid)
    |> Ash.read_one!(authorize?: false)
  end
end
