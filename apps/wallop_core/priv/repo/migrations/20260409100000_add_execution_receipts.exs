defmodule WallopCore.Repo.Migrations.AddExecutionReceipts do
  @moduledoc """
  Adds the infrastructure signing key table and the execution receipts
  table, with immutability/append-only triggers on both.

  Part of the execution receipt protocol change: the wallop infrastructure
  key signs execution attestations (separate from the operator key which
  signs commitments).
  """
  use Ecto.Migration

  def up do
    # ----- infrastructure_signing_keys -----

    create table(:infrastructure_signing_keys, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :key_id, :text, null: false
      add :public_key, :binary, null: false
      add :private_key, :binary, null: false
      add :valid_from, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:infrastructure_signing_keys, [:key_id],
             name: "infrastructure_signing_keys_unique_key_id_index"
           )

    execute("""
    CREATE OR REPLACE FUNCTION prevent_infra_key_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'infrastructure_signing_keys is append-only — UPDATE forbidden';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'infrastructure_signing_keys is append-only — DELETE forbidden';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER infra_key_immutability
    BEFORE UPDATE OR DELETE ON infrastructure_signing_keys
    FOR EACH ROW EXECUTE FUNCTION prevent_infra_key_mutation();
    """)

    # ----- execution_receipts -----

    create table(:execution_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")

      add :draw_id,
          references(:draws, column: :id, type: :uuid, name: "execution_receipts_draw_id_fkey"),
          null: false

      add :operator_id, :uuid, null: false
      add :sequence, :bigint, null: false
      add :lock_receipt_hash, :text, null: false
      add :payload_jcs, :binary, null: false
      add :signature, :binary, null: false
      add :signing_key_id, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:execution_receipts, [:draw_id],
             name: "execution_receipts_unique_draw_index"
           )

    create index(:execution_receipts, [:operator_id, :sequence],
             name: "execution_receipts_operator_sequence_index"
           )

    execute("""
    CREATE OR REPLACE FUNCTION prevent_execution_receipt_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'execution_receipts is append-only — UPDATE forbidden';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'execution_receipts is append-only — DELETE forbidden';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER execution_receipt_immutability
    BEFORE UPDATE OR DELETE ON execution_receipts
    FOR EACH ROW EXECUTE FUNCTION prevent_execution_receipt_mutation();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS execution_receipt_immutability ON execution_receipts;")
    execute("DROP FUNCTION IF EXISTS prevent_execution_receipt_mutation();")
    drop_if_exists(
      unique_index(:execution_receipts, [:draw_id], name: "execution_receipts_unique_draw_index")
    )

    drop_if_exists(
      index(:execution_receipts, [:operator_id, :sequence],
        name: "execution_receipts_operator_sequence_index"
      )
    )

    drop constraint(:execution_receipts, "execution_receipts_draw_id_fkey")
    drop table(:execution_receipts)

    execute("DROP TRIGGER IF EXISTS infra_key_immutability ON infrastructure_signing_keys;")
    execute("DROP FUNCTION IF EXISTS prevent_infra_key_mutation();")
    drop_if_exists(
      unique_index(:infrastructure_signing_keys, [:key_id],
        name: "infrastructure_signing_keys_unique_key_id_index"
      )
    )

    drop table(:infrastructure_signing_keys)
  end
end
