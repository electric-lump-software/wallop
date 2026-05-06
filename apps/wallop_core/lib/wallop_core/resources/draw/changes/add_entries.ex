defmodule WallopCore.Resources.Draw.Changes.AddEntries do
  @moduledoc """
  Appends entries to an open draw by creating Entry records, with
  idempotency replay (ADR-0012).

  Each entry gets a server-generated UUID (the Ash PK `id`, from
  `Ash.UUID.generate/0`). Structural validation is handled by
  `ValidateEntries`; client_ref hashing + plaintext clearing by
  `HashAndClearClientRef`; idempotency conflict-check by
  `CheckIdempotency`. By the time this change runs, the changeset
  context carries `:idempotency_state`, one of:

    * `{:first_write, idempotency_row_id}` — proceed with insertion.
      After entries are inserted, update the idempotency row with
      the resulting `entry_ids`. All same-tx so a crash rolls
      everything back atomically.

    * `{:replay, [entry_id, ...]}` — a prior request with the same
      `client_ref_digest` and `payload_digest` already succeeded.
      Short-circuit: do NOT insert new entries; re-fetch the cached
      ones and surface them under metadata `:inserted_entries` in
      submission order.

  After-action stashes the `:inserted_entries` UUIDs on the returned
  Draw struct under metadata. The HTTP controller for
  `PATCH /draws/:id/entries` reads them via
  `Ash.Resource.get_metadata(draw, :inserted_entries)`.
  """
  use Ash.Resource.Change

  alias Ash.Error.Invalid
  alias WallopCore.Repo
  alias WallopCore.Resources.Entry

  import Ecto.Query

  @max_entries 10_000

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.errors != [] do
      # An earlier change failed. Bail out without touching the DB.
      changeset
    else
      # Reserve the entry-count attribute change up-front (Ash needs it
      # in the changeset for the data-layer write). The first/replay
      # branch is decided in the after_action callback, where the
      # context populated by CheckIdempotency.before_action is visible.
      #
      # IDEMPOTENCY INVARIANT: the conflict-check `INSERT…ON CONFLICT`
      # in CheckIdempotency.before_action and the entry inserts +
      # idempotency-row finalisation in this after_action MUST remain
      # in the same transaction. The wrapping action transaction is
      # what gives us "concurrent retry blocks on the row lock and
      # then sees the populated entry_ids on its own retry." Refactoring
      # entry insertion to async/Oban or any out-of-tx mechanism
      # collapses this property. See ADR-0012.
      new_entries = Ash.Changeset.get_argument(changeset, :entries) || []
      current_count = changeset.data.entry_count || 0
      new_count = current_count + length(new_entries)

      if new_count > @max_entries do
        Ash.Changeset.add_error(changeset,
          field: :entries,
          message: "total entries must not exceed #{@max_entries}"
        )
      else
        changeset
        |> Ash.Changeset.force_change_attribute(:entry_count, new_count)
        |> Ash.Changeset.after_action(&dispatch_after_action/2)
      end
    end
  end

  defp dispatch_after_action(changeset, draw) do
    case Map.get(changeset.context, :idempotency_state) do
      {:replay, entry_ids} ->
        # No DB writes — re-fetch cached entries and surface them.
        # Skip PubSub broadcast (no state change occurred). Note we
        # also un-do the entry_count bump that change/3 set, since
        # the entries already exist from the original call.
        _ = fetch_entries_in_order(draw.id, entry_ids)

        # Restore the prior entry_count so the in-memory struct matches DB.
        # The DB row's entry_count was bumped by the ATTRIBUTE_UPDATE — but
        # we want replay to be idempotent at the storage layer too. So we
        # need to revert the entry_count update before returning.
        # Simplest: re-fetch the draw to get the canonical state.
        canonical_draw = WallopCore.Repo.get!(WallopCore.Resources.Draw, draw.id)

        {:ok,
         draw
         |> Map.put(:entry_count, canonical_draw.entry_count)
         |> Ash.Resource.put_metadata(:inserted_entries, entry_ids)}

      {:first_write, idempotency_row_id} ->
        new_entries = Ash.Changeset.get_argument(changeset, :entries) || []
        inserted = insert_entries(draw, new_entries)
        :ok = finalise_idempotency_row(idempotency_row_id, inserted)

        WallopCore.DrawPubSub.broadcast(draw)
        {:ok, Ash.Resource.put_metadata(draw, :inserted_entries, inserted)}

      nil ->
        {:error,
         Invalid.exception(
           errors: [
             [
               field: :client_ref,
               message: "internal: idempotency state missing — CheckIdempotency must run first"
             ]
           ]
         )}
    end
  end

  # Returns the inserted Entry UUIDs in the SAME order as the caller's
  # submitted `entries` argument. Order preservation is part of the
  # public HTTP contract — `meta.inserted_entries[i].uuid` matches the
  # i-th submitted entry.
  @spec insert_entries(map(), [map()]) :: [String.t()]
  defp insert_entries(draw, entries) do
    inputs =
      Enum.map(entries, fn entry ->
        %{
          id: Ash.UUID.generate(),
          draw_id: draw.id,
          weight: entry["weight"] || entry[:weight]
        }
      end)

    Ash.bulk_create!(inputs, Entry, :create,
      authorize?: false,
      return_errors?: true,
      stop_on_error?: true
    )

    Enum.map(inputs, & &1.id)
  end

  defp finalise_idempotency_row(row_id, entry_ids) do
    {1, _} =
      from(r in WallopCore.Resources.AddEntriesIdempotency,
        where: r.id == ^row_id,
        update: [set: [entry_ids: ^entry_ids]]
      )
      |> Repo.update_all([])

    :ok
  end

  defp fetch_entries_in_order(draw_id, entry_ids) do
    rows =
      from(e in WallopCore.Resources.Entry,
        where: e.draw_id == ^draw_id and e.id in ^entry_ids,
        select: %{id: e.id, weight: e.weight}
      )
      |> Repo.all()

    by_id = Map.new(rows, fn %{id: id} = r -> {id, r} end)
    Enum.map(entry_ids, fn id -> Map.get(by_id, id) end)
  end
end
