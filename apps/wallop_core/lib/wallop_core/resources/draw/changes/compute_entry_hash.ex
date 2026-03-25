defmodule WallopCore.Resources.Draw.Changes.ComputeEntryHash do
  @moduledoc """
  Computes the entry hash and canonical JSON on draw creation.

  Takes the `entries` attribute (list of string-keyed maps from JSON input),
  converts to atom-keyed maps, and calls `WallopCore.Protocol.entry_hash/1`.
  Stores both the hex hash and canonical JSON string.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :entries) do
      nil ->
        changeset

      entries ->
        atom_entries = WallopCore.Entries.to_atom_keys(entries)
        {hash, canonical} = WallopCore.Protocol.entry_hash(atom_entries)

        changeset
        |> Ash.Changeset.force_change_attribute(:entry_hash, hash)
        |> Ash.Changeset.force_change_attribute(:entry_canonical, canonical)
    end
  end
end
