defmodule WallopCore.Repo.Migrations.CreateTransparencyAnchors do
  use Ecto.Migration

  def change do
    create table(:transparency_anchors, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :merkle_root, :binary, null: false
      add :receipt_count, :integer, null: false
      add :from_receipt_id, :uuid, null: true
      add :to_receipt_id, :uuid, null: false
      add :external_anchor_kind, :string, null: true
      add :external_anchor_evidence, :string, null: true
      add :anchored_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:transparency_anchors, [:anchored_at])

    execute """
    CREATE OR REPLACE FUNCTION prevent_anchor_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'transparency_anchors is append-only';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'transparency_anchors is append-only';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """,
            "DROP FUNCTION IF EXISTS prevent_anchor_mutation();"

    execute """
            CREATE TRIGGER transparency_anchors_immutable
            BEFORE UPDATE OR DELETE ON transparency_anchors
            FOR EACH ROW EXECUTE FUNCTION prevent_anchor_mutation();
            """,
            "DROP TRIGGER IF EXISTS transparency_anchors_immutable ON transparency_anchors;"
  end
end
