defmodule WallopCore.Resources.Draw.Changes.LockDraw do
  @moduledoc """
  Locks an open draw: validates entries, computes entry hash, and
  delegates to DeclareEntropy for entropy source declaration.

  Runs as before_action so all changes are applied in a single DB write.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &lock/1)
  end

  defp lock(changeset) do
    draw = changeset.data
    entries = draw.entries || []

    cond do
      entries == [] ->
        Ash.Changeset.add_error(changeset, field: :entries, message: "draw has no entries")

      length(entries) < draw.winner_count ->
        Ash.Changeset.add_error(changeset,
          field: :entries,
          message: "entries (#{length(entries)}) must be >= winner_count (#{draw.winner_count})"
        )

      true ->
        atom_entries = WallopCore.Entries.to_atom_keys(entries)
        {hash, canonical} = WallopCore.Protocol.entry_hash(atom_entries)

        changeset
        |> Ash.Changeset.force_change_attribute(:entry_hash, hash)
        |> Ash.Changeset.force_change_attribute(:entry_canonical, canonical)
        |> Ash.Changeset.after_action(fn _changeset, draw ->
          Phoenix.PubSub.broadcast(
            WallopWeb.PubSub,
            "draw:#{draw.id}",
            {:draw_updated, draw}
          )

          {:ok, draw}
        end)
    end
  end
end
