defmodule WallopCore.Repo.Migrations.CreateOperators do
  use Ecto.Migration

  def change do
    create table(:operators, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :slug, :citext, null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:operators, [:slug])

    create table(:operator_signing_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :operator_id, references(:operators, type: :uuid, on_delete: :restrict), null: false
      add :key_id, :string, null: false
      add :public_key, :binary, null: false
      add :private_key, :binary, null: false
      add :valid_from, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:operator_signing_keys, [:operator_id])
    create unique_index(:operator_signing_keys, [:operator_id, :key_id])

    execute """
    CREATE OR REPLACE FUNCTION prevent_signing_key_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'operator_signing_keys is append-only';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'operator_signing_keys is append-only';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """,
            "DROP FUNCTION IF EXISTS prevent_signing_key_mutation();"

    execute """
            CREATE TRIGGER operator_signing_keys_immutable
            BEFORE UPDATE OR DELETE ON operator_signing_keys
            FOR EACH ROW EXECUTE FUNCTION prevent_signing_key_mutation();
            """,
            "DROP TRIGGER IF EXISTS operator_signing_keys_immutable ON operator_signing_keys;"
  end
end
