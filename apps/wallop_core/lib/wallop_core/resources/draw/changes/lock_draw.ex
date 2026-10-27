defmodule WallopCore.Resources.Draw.Changes.LockDraw do
  @moduledoc """
  Locks an open draw: validates entry count, computes entry hash from
  the entries table and prunes idempotency rows. The entropy declaration
  is the tag's own change (`DeclareEntropyV6` or `DeclareEntropyFreq`).

  Runs as before_action so all changes are applied in a single DB write
  inside the action's transaction. The idempotency prune is
  same-tx with the `:open -> :locked` state change: a crash between
  prune and lock-commit rolls both back atomically, so no draw can be
  observed in a state where idempotency rows outlive their open phase.
  """
  use Ash.Resource.Change

  import Ecto.Query

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
        WallopCore.Repo.query!(
          "SELECT id FROM draws WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(draw.id)]
        )

        entries = WallopCore.Entries.load_for_draw(draw.id)
        {hash, canonical} = WallopCore.Protocol.entry_hash({draw.id, entries})

        :ok = prune_idempotency_rows(draw.id)

        changeset
        |> Ash.Changeset.force_change_attribute(:entry_hash, hash)
        |> Ash.Changeset.force_change_attribute(:entry_canonical, canonical)
        |> Ash.Changeset.after_action(fn _changeset, draw -> announce(draw) end)
    end
  end

  defp announce(%{lock_schema_version: "6"} = draw), do: {:ok, draw}

  defp announce(draw) do
    WallopCore.DrawPubSub.broadcast(draw)
    {:ok, draw}
  end

  defp prune_idempotency_rows(draw_id) do
    {_n, _} =
      from(r in WallopCore.Resources.AddEntriesIdempotency,
        where: r.draw_id == ^draw_id
      )
      |> WallopCore.Repo.delete_all()

    :ok
  end
end
