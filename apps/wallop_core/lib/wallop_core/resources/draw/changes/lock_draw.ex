defmodule WallopCore.Resources.Draw.Changes.LockDraw do
  @moduledoc """
  Locks an open draw: validates entry count, computes entry hash from
  the entries table, prunes idempotency rows, and delegates to
  DeclareEntropy.

  Runs as before_action so all changes are applied in a single DB write
  inside the action's transaction. The idempotency prune (ADR-0012) is
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
        # Acquire row lock on the draw BEFORE reading entries. This
        # serializes with the entries trigger's own FOR UPDATE on the
        # draw row, closing the TOCTOU window where an entry insert
        # could sneak in between hash computation and the draw UPDATE.
        WallopCore.Repo.query!(
          "SELECT id FROM draws WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(draw.id)]
        )

        entries = WallopCore.Entries.load_for_draw(draw.id)
        {hash, canonical} = WallopCore.Protocol.entry_hash({draw.id, entries})

        # Prune idempotency rows for this draw — same transaction as
        # the :open -> :locked state change. ADR-0012.
        :ok = prune_idempotency_rows(draw.id)

        changeset
        |> Ash.Changeset.force_change_attribute(:entry_hash, hash)
        |> Ash.Changeset.force_change_attribute(:entry_canonical, canonical)
        |> Ash.Changeset.after_action(fn _changeset, draw ->
          WallopCore.DrawPubSub.broadcast(draw)
          {:ok, draw}
        end)
    end
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
