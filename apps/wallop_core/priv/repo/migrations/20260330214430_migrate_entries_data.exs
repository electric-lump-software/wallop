defmodule WallopCore.Repo.Migrations.MigrateEntriesData do
  @moduledoc """
  Migrates existing entry data from the JSONB `entries` column on draws
  to the new `entries` table. Also sets `entry_count` from the migrated data.
  """
  use Ecto.Migration

  def up do
    # Temporarily disable immutability triggers for data migration
    execute "ALTER TABLE entries DISABLE TRIGGER entries_immutability"
    execute "ALTER TABLE draws DISABLE TRIGGER enforce_draw_immutability"

    # entries column is {:array, :map} which Postgres stores as jsonb[].
    # Use unnest to expand the array, then extract fields from each element.
    execute """
    INSERT INTO entries (id, draw_id, entry_id, weight, inserted_at)
    SELECT
      gen_random_uuid(),
      d.id,
      (entry->>'id')::text,
      (entry->>'weight')::integer,
      d.inserted_at
    FROM draws d,
      unnest(d.entries) AS entry
    WHERE d.entries IS NOT NULL
      AND array_length(d.entries, 1) > 0
    ON CONFLICT (draw_id, entry_id) DO NOTHING
    """

    execute """
    UPDATE draws SET entry_count = (
      SELECT COUNT(*) FROM entries WHERE entries.draw_id = draws.id
    )
    """

    # Re-enable triggers
    execute "ALTER TABLE entries ENABLE TRIGGER entries_immutability"
    execute "ALTER TABLE draws ENABLE TRIGGER enforce_draw_immutability"
  end

  def down do
    execute "DELETE FROM entries"
    execute "UPDATE draws SET entry_count = 0"
  end
end
