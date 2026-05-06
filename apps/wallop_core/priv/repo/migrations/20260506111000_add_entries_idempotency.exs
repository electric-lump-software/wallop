defmodule WallopCore.Repo.Migrations.AddEntriesIdempotency do
  @moduledoc """
  Side table for `Draw.add_entries` idempotent retries (ADR-0012).

  Operators supply a `client_ref` per batch. The boundary hashes it
  to a `client_ref_digest` (plaintext is never persisted). The
  canonical entry-multiset payload is hashed to `payload_digest`.
  On retry, matching `(draw_id, client_ref_digest)` + matching
  `payload_digest` replays the cached `entry_ids`. Mismatching
  `payload_digest` returns 409.

  Cascade-on-draw-delete is structural; the prune-at-lock hook is
  operational. Both exist deliberately. The table is operational
  metadata only — never read during receipt construction. See ADR.
  """

  use Ecto.Migration

  def up do
    create table(:add_entries_idempotency, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :draw_id,
        references(:draws,
          column: :id,
          type: :uuid,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:client_ref_digest, :binary, null: false)
      add(:payload_digest, :binary, null: false)
      add(:entry_ids, {:array, :uuid}, null: false)

      add(
        :inserted_at,
        :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:add_entries_idempotency, [:draw_id, :client_ref_digest],
        name: "add_entries_idempotency_draw_client_ref_index"
      )
    )
  end

  def down do
    drop(table(:add_entries_idempotency))
  end
end
