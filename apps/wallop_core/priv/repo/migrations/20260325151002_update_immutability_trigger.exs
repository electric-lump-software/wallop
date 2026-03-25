defmodule WallopCore.Repo.Migrations.UpdateImmutabilityTrigger do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION prevent_draw_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      -- Terminal states: block ALL changes
      IF OLD.status IN ('completed', 'failed') THEN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Cannot delete a % draw', OLD.status;
        END IF;
        RAISE EXCEPTION 'Cannot modify a % draw', OLD.status;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        -- Enforce valid state transitions
        IF OLD.status = 'locked' AND NEW.status NOT IN ('locked', 'awaiting_entropy', 'completed') THEN
          RAISE EXCEPTION 'Invalid state transition from locked to %', NEW.status;
        END IF;
        IF OLD.status = 'awaiting_entropy' AND NEW.status NOT IN ('awaiting_entropy', 'pending_entropy') THEN
          RAISE EXCEPTION 'Invalid state transition from awaiting_entropy to %', NEW.status;
        END IF;
        IF OLD.status = 'pending_entropy' AND NEW.status NOT IN ('pending_entropy', 'completed', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from pending_entropy to %', NEW.status;
        END IF;

        -- Block caller-seed execute if entropy sources are declared
        IF OLD.drand_round IS NOT NULL AND NEW.seed_source = 'caller' THEN
          RAISE EXCEPTION 'Cannot use caller-provided seed when entropy sources are declared';
        END IF;

        -- Protect committed fields (all non-terminal states)
        IF NEW.entries IS DISTINCT FROM OLD.entries
           OR NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
           OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical
           OR NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN
          RAISE EXCEPTION 'Cannot modify committed entry fields';
        END IF;

        -- Protect declared entropy fields (awaiting_entropy and pending_entropy)
        IF OLD.status IN ('awaiting_entropy', 'pending_entropy') THEN
          IF NEW.drand_round IS DISTINCT FROM OLD.drand_round
             OR NEW.drand_chain IS DISTINCT FROM OLD.drand_chain
             OR NEW.weather_station IS DISTINCT FROM OLD.weather_station
             OR NEW.weather_time IS DISTINCT FROM OLD.weather_time THEN
            RAISE EXCEPTION 'Cannot modify declared entropy fields';
          END IF;
        END IF;
      END IF;

      -- Allow DELETE on non-terminal states
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  def down do
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
  end
end
