defmodule WallopCore.Resources.Draw.Changes.RemoveEntry do
  @moduledoc """
  Removes a single entry from an open draw by entry ID.
  """
  use Ash.Resource.Change

  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    draw = changeset.data
    entry_id = Ash.Changeset.get_argument(changeset, :entry_id)

    # Check existence first (before the action filter runs)
    if entry_exists?(draw.id, entry_id) do
      new_count = max((draw.entry_count || 0) - 1, 0)

      changeset
      |> Ash.Changeset.force_change_attribute(:entry_count, new_count)
      |> Ash.Changeset.after_action(fn _changeset, draw ->
        delete_entry(draw.id, entry_id)
        Phoenix.PubSub.broadcast(WallopCore.PubSub, "draw:#{draw.id}", {:draw_updated, draw})
        {:ok, draw}
      end)
    else
      Ash.Changeset.add_error(changeset, field: :entry_id, message: "entry not found")
    end
  end

  @spec entry_exists?(String.t(), String.t()) :: boolean()
  defp entry_exists?(draw_id, entry_id) do
    from(e in "entries",
      where: e.draw_id == type(^draw_id, :binary_id) and e.entry_id == ^entry_id,
      select: true
    )
    |> WallopCore.Repo.exists?()
  end

  @spec delete_entry(String.t(), String.t()) :: {non_neg_integer(), nil}
  defp delete_entry(draw_id, entry_id) do
    from(e in "entries",
      where: e.draw_id == type(^draw_id, :binary_id) and e.entry_id == ^entry_id
    )
    |> WallopCore.Repo.delete_all()
  end
end
