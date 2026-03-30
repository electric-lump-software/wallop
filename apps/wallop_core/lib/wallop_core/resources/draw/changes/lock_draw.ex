defmodule WallopCore.Resources.Draw.Changes.LockDraw do
  @moduledoc """
  Locks an open draw: validates entry count, computes entry hash from
  the entries table, and delegates to DeclareEntropy.

  Runs as before_action so all changes are applied in a single DB write.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &lock/1)
  end

  defp lock(changeset) do
    draw = changeset.data
    entry_count = draw.entry_count || 0

    cond do
      entry_count == 0 ->
        Ash.Changeset.add_error(changeset, field: :entries, message: "draw has no entries")

      entry_count < draw.winner_count ->
        Ash.Changeset.add_error(changeset,
          field: :entries,
          message: "entries (#{entry_count}) must be >= winner_count (#{draw.winner_count})"
        )

      true ->
        atom_entries = WallopCore.Entries.load_for_draw(draw.id)
        {hash, canonical} = WallopCore.Protocol.entry_hash(atom_entries)

        changeset
        |> Ash.Changeset.force_change_attribute(:entry_hash, hash)
        |> Ash.Changeset.force_change_attribute(:entry_canonical, canonical)
        |> Ash.Changeset.after_action(fn _changeset, draw ->
          Phoenix.PubSub.broadcast(
            WallopCore.PubSub,
            "draw:#{draw.id}",
            {:draw_updated, draw}
          )

          {:ok, draw}
        end)
    end
  end
end
