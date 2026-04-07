defmodule WallopCore.Repo.Migrations.CreateOperatorReceipts do
  use Ecto.Migration

  def change do
    create table(:operator_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :operator_id, references(:operators, type: :uuid, on_delete: :restrict), null: false
      add :draw_id, references(:draws, type: :uuid, on_delete: :restrict), null: false
      add :sequence, :integer, null: false
      add :commitment_hash, :string, null: false
      add :entry_hash, :string, null: false
      add :locked_at, :utc_datetime_usec, null: false
      add :signing_key_id, :string, null: false
      add :payload_jcs, :binary, null: false
      add :signature, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:operator_receipts, [:operator_id, :sequence])
    create unique_index(:operator_receipts, [:draw_id])
    create index(:operator_receipts, [:operator_id, :inserted_at])

    execute """
    CREATE OR REPLACE FUNCTION prevent_receipt_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'operator_receipts is append-only';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'operator_receipts is append-only';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """,
            "DROP FUNCTION IF EXISTS prevent_receipt_mutation();"

    execute """
            CREATE TRIGGER operator_receipts_immutable
            BEFORE UPDATE OR DELETE ON operator_receipts
            FOR EACH ROW EXECUTE FUNCTION prevent_receipt_mutation();
            """,
            "DROP TRIGGER IF EXISTS operator_receipts_immutable ON operator_receipts;"
  end
end
