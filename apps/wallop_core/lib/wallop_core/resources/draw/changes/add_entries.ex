defmodule WallopCore.Resources.Draw.Changes.AddEntries do
  @moduledoc """
  Appends entries to an open draw by creating Entry records.

  Each entry gets a server-generated UUID (the Ash PK `id`, from Postgres
  `gen_random_uuid()`). Structural validation is handled by
  `ValidateEntries`.

  After insertion, the inserted Entry UUIDs — in the same order as the
  caller's submitted `entries` argument — are stashed on the returned
  Draw struct under metadata key `:inserted_entries`. Callers that need
  `(submission_position ↔ wallop_uuid)` correlation (e.g. the HTTP
  controller for `PATCH /draws/:id/entries`) read them via
  `Ash.Resource.get_metadata(draw, :inserted_entries)`.
  """
  use Ash.Resource.Change

  alias WallopCore.Resources.Entry

  @max_entries 10_000

  @impl true
  def change(changeset, _opts, _context) do
    draw = changeset.data
    new_entries = Ash.Changeset.get_argument(changeset, :entries)

    current_count = draw.entry_count || 0
    new_count = current_count + length(new_entries)

    if new_count > @max_entries do
      Ash.Changeset.add_error(changeset,
        field: :entries,
        message: "total entries must not exceed #{@max_entries}"
      )
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:entry_count, new_count)
      |> Ash.Changeset.after_action(fn _changeset, draw ->
        inserted = insert_entries(draw, new_entries)

        WallopCore.DrawPubSub.broadcast(draw)
        {:ok, Ash.Resource.put_metadata(draw, :inserted_entries, inserted)}
      end)
    end
  end

  # Returns the inserted Entry UUIDs in the SAME order as the caller's
  # submitted `entries` argument. Order preservation is part of the
  # public HTTP contract — `meta.inserted_entries[i].uuid` matches the
  # i-th submitted entry.
  #
  # Ash.bulk_create! with `return_records?: true` does NOT contractually
  # guarantee input-order on returned records — batching + data-layer
  # delegation make that incidental, not specified. So we pre-generate
  # the Entry UUIDs in Elixir (via Ash.UUID.generate/0, which uses
  # :crypto.strong_rand_bytes/1 — still server-side, entropy invariant
  # intact) and hand them to the insert as explicit `id` values. The
  # correlation becomes tautological: emit the UUID we generated for
  # position i.
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
end
