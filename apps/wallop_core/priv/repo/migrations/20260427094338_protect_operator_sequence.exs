defmodule WallopCore.Repo.Migrations.ProtectOperatorSequence do
  @moduledoc """
  Belt-and-braces: extend the draw immutability trigger to forbid
  mutation of `operator_sequence` once status leaves `open`.

  `operator_sequence` is assigned at lock time inside an advisory-locked
  transaction (gap-free per-operator sequencing). Once a draw locks,
  the sequence number occupies a public slot in the operator's
  registry listing and the cross-draw verifiability property requires
  it to remain stable until the draw reaches a terminal state.

  In practice the existing trigger already blocks the realistic attack
  surface — the entire row is immutable at status `completed | failed
  | expired`, and lock + sequence-assignment + receipt-signing all
  happen in a single Ash transaction so there's no exploitable window
  during the brief `locked → awaiting_entropy` transition. This
  migration closes that theoretical window for defence-in-depth: any
  future code path that rewrites `operator_sequence` post-lock is now
  blocked at the storage layer.

  No behaviour change for production paths — sequence is set once at
  lock and never written again.
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

  def down do
    # Restore the prior trigger body without the operator_sequence check.
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
             OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical THEN
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
