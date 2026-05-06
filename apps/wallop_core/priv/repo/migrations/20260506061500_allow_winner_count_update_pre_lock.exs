defmodule WallopCore.Repo.Migrations.AllowWinnerCountUpdatePreLock do
  @moduledoc """
  Relax the `prevent_draw_mutation` trigger so `winner_count` can be
  modified while `status = 'open'`. Once a draw transitions out of
  `:open`, `winner_count` becomes immutable (it is committed in the
  signed lock receipt and consumed by `fair_pick`; changing it post-
  lock would invalidate the receipt).

  Mirrors the existing `:update_winner_count` Ash action's filter
  (`status == :open`) and policy at the storage layer. Existing pre-
  lock-only field rules in this trigger (entry_hash, entry_canonical,
  operator_sequence, drand_*, weather_*) are unchanged — they stay
  mutable while open and immutable once locked.

  No behaviour change for any path other than the new
  `:update_winner_count` action: every existing call site that
  modified `winner_count` was rejected and continues to be rejected
  in any non-`:open` state.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION prevent_draw_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF OLD.status IN ('completed', 'failed', 'expired') THEN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Cannot delete a % draw', OLD.status;
        END IF;
        RAISE EXCEPTION 'Cannot modify a % draw', OLD.status;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF OLD.status != 'open' AND NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN
          RAISE EXCEPTION 'Cannot modify winner_count once draw has left :open';
        END IF;

        IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'awaiting_entropy', 'expired') THEN
          RAISE EXCEPTION 'Invalid state transition from open to %', NEW.status;
        END IF;
        IF OLD.status = 'locked' AND NEW.status NOT IN ('locked', 'awaiting_entropy', 'completed') THEN
          RAISE EXCEPTION 'Invalid state transition from locked to %', NEW.status;
        END IF;
        IF OLD.status = 'awaiting_entropy' AND NEW.status NOT IN ('awaiting_entropy', 'pending_entropy', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from awaiting_entropy to %', NEW.status;
        END IF;
        IF OLD.status = 'pending_entropy' AND NEW.status NOT IN ('pending_entropy', 'completed', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from pending_entropy to %', NEW.status;
        END IF;

        IF NEW.seed_source = 'sandbox' THEN
          RAISE EXCEPTION 'seed_source = sandbox is not permitted on draws — use sandbox_draws';
        END IF;

        IF OLD.drand_round IS NOT NULL AND NEW.seed_source = 'caller' THEN
          RAISE EXCEPTION 'Cannot use caller-provided seed when entropy sources are declared';
        END IF;

        IF OLD.status != 'open' THEN
          IF NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
             OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical
             OR NEW.operator_sequence IS DISTINCT FROM OLD.operator_sequence THEN
            RAISE EXCEPTION 'Cannot modify committed entry fields';
          END IF;
        END IF;

        IF OLD.status IN ('awaiting_entropy', 'pending_entropy') THEN
          IF NEW.drand_round IS DISTINCT FROM OLD.drand_round
             OR NEW.drand_chain IS DISTINCT FROM OLD.drand_chain
             OR NEW.weather_station IS DISTINCT FROM OLD.weather_station
             OR NEW.weather_time IS DISTINCT FROM OLD.weather_time THEN
            RAISE EXCEPTION 'Cannot modify declared entropy fields';
          END IF;
        END IF;
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    # Reverts to the pre-2026-05-06 trigger that blocked winner_count
    # changes unconditionally.
    execute("""
    CREATE OR REPLACE FUNCTION prevent_draw_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF OLD.status IN ('completed', 'failed', 'expired') THEN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'Cannot delete a % draw', OLD.status;
        END IF;
        RAISE EXCEPTION 'Cannot modify a % draw', OLD.status;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN
          RAISE EXCEPTION 'Cannot modify winner_count';
        END IF;

        IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'awaiting_entropy', 'expired') THEN
          RAISE EXCEPTION 'Invalid state transition from open to %', NEW.status;
        END IF;
        IF OLD.status = 'locked' AND NEW.status NOT IN ('locked', 'awaiting_entropy', 'completed') THEN
          RAISE EXCEPTION 'Invalid state transition from locked to %', NEW.status;
        END IF;
        IF OLD.status = 'awaiting_entropy' AND NEW.status NOT IN ('awaiting_entropy', 'pending_entropy', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from awaiting_entropy to %', NEW.status;
        END IF;
        IF OLD.status = 'pending_entropy' AND NEW.status NOT IN ('pending_entropy', 'completed', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from pending_entropy to %', NEW.status;
        END IF;

        IF NEW.seed_source = 'sandbox' THEN
          RAISE EXCEPTION 'seed_source = sandbox is not permitted on draws — use sandbox_draws';
        END IF;

        IF OLD.drand_round IS NOT NULL AND NEW.seed_source = 'caller' THEN
          RAISE EXCEPTION 'Cannot use caller-provided seed when entropy sources are declared';
        END IF;

        IF OLD.status != 'open' THEN
          IF NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
             OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical
             OR NEW.operator_sequence IS DISTINCT FROM OLD.operator_sequence THEN
            RAISE EXCEPTION 'Cannot modify committed entry fields';
          END IF;
        END IF;

        IF OLD.status IN ('awaiting_entropy', 'pending_entropy') THEN
          IF NEW.drand_round IS DISTINCT FROM OLD.drand_round
             OR NEW.drand_chain IS DISTINCT FROM OLD.drand_chain
             OR NEW.weather_station IS DISTINCT FROM OLD.weather_station
             OR NEW.weather_time IS DISTINCT FROM OLD.weather_time THEN
            RAISE EXCEPTION 'Cannot modify declared entropy fields';
          END IF;
        END IF;
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
