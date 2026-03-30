defmodule WallopCore.Repo.Migrations.CreateEntriesTable do
  use Ecto.Migration

  def up do
    create table(:entries, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :draw_id, references(:draws, type: :uuid, on_delete: :delete_all),
        null: false

      add :entry_id, :text, null: false
      add :weight, :integer, null: false, default: 1

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:entries, [:draw_id, :entry_id], name: "entries_unique_entry_per_draw_index")
    create index(:entries, [:draw_id])

    execute """
    CREATE OR REPLACE FUNCTION prevent_entry_mutation()
    RETURNS TRIGGER AS $$
    DECLARE
      draw_status TEXT;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        SELECT status INTO draw_status FROM draws WHERE id = NEW.draw_id FOR UPDATE;
      ELSE
        SELECT status INTO draw_status FROM draws WHERE id = OLD.draw_id FOR UPDATE;
      END IF;

      IF draw_status != 'open' THEN
        RAISE EXCEPTION 'Cannot modify entries on a % draw', draw_status;
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER entries_immutability
      BEFORE INSERT OR UPDATE OR DELETE ON entries
      FOR EACH ROW EXECUTE FUNCTION prevent_entry_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS entries_immutability ON entries"
    execute "DROP FUNCTION IF EXISTS prevent_entry_mutation()"
    drop table(:entries)
  end
end
