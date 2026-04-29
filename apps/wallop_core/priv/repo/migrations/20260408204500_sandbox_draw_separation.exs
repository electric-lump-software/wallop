defmodule WallopCore.Repo.Migrations.SandboxDrawSeparation do
  @moduledoc """
  Structurally separate sandbox draws from real draws.

  The previous design had sandbox execution as an `execute_sandbox` update
  action on the `Draw` resource, gated only by a runtime config flag
  (`allow_sandbox_execution`). The `draws.seed_source` column could be
  set to `'sandbox'` after the draw was locked, and the signed operator
  receipt did NOT commit to `seed_source`, which meant:

    1. Any consumer of `wallop_core` that set `allow_sandbox_execution: true`
       in prod (downstream consumer apps, self-hosters, misconfigured
       staging envs) could divert a real locked draw to sandbox execution
       before the entropy worker ran.
    2. The resulting draw would sit in the operator's public registry as
       a terminal row, and nothing cryptographic would contradict the
       operator's later claim of "that was only a test."

  This migration implements the schema-level fix:

    - Creates a dedicated `sandbox_draws` table with no FK to `draws`,
      no sequence counter, no receipt relationship, and no transparency
      log membership. Sandbox draws are structurally incapable of being
      confused with real draws.
    - Drops any existing sandbox rows from `draws` (pre-launch, no real
      data to preserve).
    - Rewrites the immutability trigger to forbid the `awaiting_entropy
      → completed` transition entirely. The previous carve-out allowed
      that transition if and only if `seed_source = 'sandbox'`; that
      carve-out is gone.

  Paired with the deletion of:
    - `Draw.execute_sandbox` update action
    - `Draw.Changes.ExecuteSandbox` change module
    - `:sandbox` from the `Draw.seed_source` Ash constraint
    - `config :wallop_core, :allow_sandbox_execution, ...`

  Pre-launch breaking change. Bumps wallop_core to 0.11.0. Any consumer
  calling `Draw.execute_sandbox` or setting `seed_source: :sandbox` on a
  Draw must migrate to `WallopCore.Resources.SandboxDraw`.
  """
  use Ecto.Migration

  def up do
    # Pre-launch: drop any existing sandbox rows from draws. The real
    # state transition fix below would otherwise leave these rows in an
    # invalid state (seed_source value removed from enum). Sandbox rows
    # may be in terminal state (:completed), which the existing
    # immutability trigger blocks from deletion — bypass the trigger
    # for this one DELETE via session_replication_role = replica.
    execute("""
    DO $$
    BEGIN
      SET LOCAL session_replication_role = 'replica';
      DELETE FROM draws WHERE seed_source = 'sandbox';
    END $$;
    """)

    # Create the sandbox_draws table. Entries are embedded JSON, not a
    # relation — sandbox entries are ephemeral and must never share a
    # table with real Draw entries.
    create table(:sandbox_draws, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")

      add :api_key_id,
          references(:api_keys, column: :id, type: :uuid, name: "sandbox_draws_api_key_id_fkey"),
          null: false

      add :operator_id,
          references(:operators, column: :id, type: :uuid, name: "sandbox_draws_operator_id_fkey"),
          null: true

      add :name, :text, null: true
      add :winner_count, :bigint, null: false
      add :entries, {:array, :map}, null: false, default: []
      add :seed, :text, null: false
      add :results, {:array, :map}, null: false, default: []
      add :executed_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sandbox_draws, [:api_key_id])
    create index(:sandbox_draws, [:operator_id])

    # Rewrite the draws immutability trigger to remove the sandbox
    # carve-out. Previous trigger allowed awaiting_entropy → completed
    # ONLY when seed_source = 'sandbox'; new trigger forbids that
    # transition entirely. Real draws must flow
    # awaiting_entropy → pending_entropy → completed via the entropy
    # worker, with no shortcut.
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
        -- awaiting_entropy → completed is NOT a valid transition for real
        -- draws. The sandbox carve-out that used to sit here is gone;
        -- sandbox draws live in `sandbox_draws`, not `draws`.
        IF OLD.status = 'awaiting_entropy' AND NEW.status NOT IN ('awaiting_entropy', 'pending_entropy', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from awaiting_entropy to %', NEW.status;
        END IF;
        IF OLD.status = 'pending_entropy' AND NEW.status NOT IN ('pending_entropy', 'completed', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from pending_entropy to %', NEW.status;
        END IF;

        -- Reject any attempt to write seed_source = 'sandbox' on a draws
        -- row. The value is no longer part of the Ash enum, and we
        -- belt-and-brace it here so direct SQL can't reintroduce it either.
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

  def down do
    # Restore previous trigger (with the sandbox carve-out).
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
        IF OLD.status = 'awaiting_entropy' AND NEW.status NOT IN ('awaiting_entropy', 'pending_entropy', 'completed', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from awaiting_entropy to %', NEW.status;
        END IF;
        IF OLD.status = 'awaiting_entropy' AND NEW.status = 'completed' AND NEW.seed_source != 'sandbox' THEN
          RAISE EXCEPTION 'Direct awaiting_entropy to completed requires sandbox seed_source';
        END IF;
        IF OLD.status = 'pending_entropy' AND NEW.status NOT IN ('pending_entropy', 'completed', 'failed') THEN
          RAISE EXCEPTION 'Invalid state transition from pending_entropy to %', NEW.status;
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

    drop index(:sandbox_draws, [:operator_id])
    drop index(:sandbox_draws, [:api_key_id])
    drop constraint(:sandbox_draws, "sandbox_draws_operator_id_fkey")
    drop constraint(:sandbox_draws, "sandbox_draws_api_key_id_fkey")
    drop table(:sandbox_draws)
  end
end
