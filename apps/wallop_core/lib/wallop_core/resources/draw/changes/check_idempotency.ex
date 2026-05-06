defmodule WallopCore.Resources.Draw.Changes.CheckIdempotency do
  @moduledoc """
  Idempotency conflict-check for `Draw.add_entries` (ADR-0012).

  Runs after `HashAndClearClientRef` (which stashes both digests in
  the changeset context) and before `AddEntries` (which performs
  the actual entry inserts).

  Three outcomes, all materialised as context flags consumed by
  `AddEntries`:

  - **First write.** `INSERT ... ON CONFLICT DO NOTHING RETURNING`
    returns a row → stash `:idempotency_state = {:first_write, row_id}`.
    `AddEntries` does its normal insertion path and then updates the
    idempotency row with the resulting `entry_ids`. All same-tx.

  - **Replay.** Conflict → re-read existing row, compare the stored
    `payload_digest` against the freshly computed one. Match →
    stash `:idempotency_state = {:replay, entry_ids}`. `AddEntries`
    short-circuits and re-fetches the cached entries.

  - **Conflict.** Same `client_ref_digest`, different
    `payload_digest` → adds a changeset error tagged so the
    controller can map it to HTTP 409. The action's transaction
    rolls back; nothing persists.

  This change runs inside the action's transaction (Ash wraps
  update actions in a tx by default; see ADR-0012 "Same-transaction
  insertion is the only construction that closes the orphan-digest
  window"). A crash between this insert and the entry inserts will
  roll BOTH back atomically.
  """
  use Ash.Resource.Change

  alias WallopCore.Repo
  alias WallopCore.Resources.AddEntriesIdempotency

  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.errors != [] do
      changeset
    else
      Ash.Changeset.before_action(changeset, &perform_check/1)
    end
  end

  defp perform_check(changeset) do
    draw_id = changeset.data.id
    client_ref_digest = Map.get(changeset.context, :client_ref_digest)
    payload_digest = Map.get(changeset.context, :payload_digest)

    if is_nil(client_ref_digest) or is_nil(payload_digest) do
      Ash.Changeset.add_error(changeset,
        field: :client_ref,
        message: "internal: digests missing — HashAndClearClientRef must run first"
      )
    else
      do_insert_or_lookup(changeset, draw_id, client_ref_digest, payload_digest)
    end
  end

  # Try to insert the idempotency row with empty entry_ids. If the
  # insert wins, the action proceeds and AddEntries fills the row
  # at the end. If it conflicts, a row already exists — look it up,
  # compare payload_digest, and either flag replay or 409.
  defp do_insert_or_lookup(changeset, draw_id, client_ref_digest, payload_digest) do
    attempt_insert(draw_id, client_ref_digest, payload_digest)
    |> handle_insert_result(changeset, draw_id, client_ref_digest, payload_digest)
  end

  defp attempt_insert(draw_id, client_ref_digest, payload_digest) do
    now = DateTime.utc_now()

    # `on_conflict: :nothing` with the unique-index conflict_target gives
    # atomic dedup under READ COMMITTED: a second concurrent inserter
    # blocks on the row lock from the in-flight tx, then on commit sees
    # the conflict and skips (returns 0 rows). If isolation is ever
    # raised to REPEATABLE READ, the second tx will get a serialization
    # failure on conflict — adapt the retry strategy if so.
    Repo.insert_all(
      AddEntriesIdempotency,
      [
        %{
          id: Ash.UUID.generate(),
          draw_id: draw_id,
          client_ref_digest: client_ref_digest,
          payload_digest: payload_digest,
          entry_ids: [],
          inserted_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:draw_id, :client_ref_digest],
      returning: [:id]
    )
  end

  defp handle_insert_result(
         {1, [%{id: row_id}]},
         changeset,
         _draw_id,
         _client_ref_digest,
         _payload_digest
       ) do
    Ash.Changeset.put_context(
      changeset,
      :idempotency_state,
      {:first_write, row_id}
    )
  end

  defp handle_insert_result(
         {0, _},
         changeset,
         draw_id,
         client_ref_digest,
         payload_digest
       ) do
    case lookup_existing(draw_id, client_ref_digest) do
      nil ->
        # Race: row was deleted between conflict and lookup. Treat as
        # internal — should not be possible while the draw is :open
        # (only the lock action prunes; lock changes status away from
        # :open and the action filter would have already rejected).
        Ash.Changeset.add_error(changeset,
          field: :client_ref,
          message: "internal: idempotency row vanished after conflict"
        )

      %{payload_digest: stored, entry_ids: entry_ids} ->
        if stored == payload_digest do
          Ash.Changeset.put_context(
            changeset,
            :idempotency_state,
            {:replay, entry_ids}
          )
        else
          Ash.Changeset.add_error(changeset, %WallopCore.Errors.IdempotencyConflict{
            field: :client_ref,
            message:
              "client_ref already used for a different entry batch on this draw " <>
                "(payload_digest mismatch)"
          })
        end
    end
  end

  defp lookup_existing(draw_id, client_ref_digest) do
    from(r in AddEntriesIdempotency,
      where: r.draw_id == ^draw_id and r.client_ref_digest == ^client_ref_digest,
      select: %{payload_digest: r.payload_digest, entry_ids: r.entry_ids}
    )
    |> Repo.one()
  end
end
