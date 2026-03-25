defmodule WallopCore.Repo.Migrations.AddImmutabilityTrigger do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION prevent_draw_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      -- Completed draws: block ALL changes (update and delete)
      IF OLD.status = 'completed' THEN
        RAISE EXCEPTION 'Cannot modify or delete a completed draw';
      END IF;

      -- Locked draws: protect committed fields
      IF TG_OP = 'UPDATE' AND OLD.status = 'locked' THEN
        IF NEW.entries IS DISTINCT FROM OLD.entries
           OR NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
           OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical
           OR NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN
          RAISE EXCEPTION 'Cannot modify committed fields on a locked draw';
        END IF;
      END IF;

      -- For DELETE, return OLD to allow the operation; for UPDATE return NEW
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER enforce_draw_immutability
      BEFORE UPDATE OR DELETE ON draws
      FOR EACH ROW
      EXECUTE FUNCTION prevent_draw_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS enforce_draw_immutability ON draws;"
    execute "DROP FUNCTION IF EXISTS prevent_draw_mutation();"
  end
end
