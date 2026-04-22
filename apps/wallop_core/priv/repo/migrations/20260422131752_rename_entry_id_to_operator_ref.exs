defmodule WallopCore.Repo.Migrations.RenameEntryIdToOperatorRef do
  @moduledoc """
  Repurpose `entry_id` as `operator_ref`:

  - Drop the `(draw_id, entry_id)` unique index (the PK `id` is the public
    UUID bound into entry_hash — unique globally by construction).
  - Drop the `entry_id` column (length/regex/PII rejection no longer needed).
  - Add `operator_ref` (nullable, length enforced at the application layer).

  Pre-launch: no data to preserve. Destructive is fine.

  The `prevent_entry_mutation` trigger is unaffected — it does not reference
  column names.
  """
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS entries_unique_entry_per_draw_index")

    alter table(:entries) do
      remove :entry_id
      add :operator_ref, :text, null: true
    end
  end

  def down do
    alter table(:entries) do
      remove :operator_ref
      add :entry_id, :text, null: false
    end

    create unique_index(:entries, [:draw_id, :entry_id],
             name: "entries_unique_entry_per_draw_index"
           )
  end
end
