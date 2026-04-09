defmodule WallopCore.Repo.Migrations.AddTruncateProtection do
  @moduledoc """
  Add TRUNCATE protection to all tables with immutability triggers.

  Row-level triggers (BEFORE UPDATE OR DELETE) do not fire on TRUNCATE.
  A statement-level BEFORE TRUNCATE trigger prevents silent mass deletion
  of signed artefacts and committed draw data.
  """
  use Ecto.Migration

  @protected_tables ~w(
    draws
    entries
    operator_signing_keys
    operator_receipts
    transparency_anchors
    infrastructure_signing_keys
    execution_receipts
  )

  def up do
    for table <- @protected_tables do
      execute("""
      CREATE OR REPLACE FUNCTION prevent_#{table}_truncate()
      RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION '#{table} cannot be TRUNCATEd — use row-level DELETE with appropriate permissions';
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE TRIGGER #{table}_no_truncate
      BEFORE TRUNCATE ON #{table}
      EXECUTE FUNCTION prevent_#{table}_truncate();
      """)
    end
  end

  def down do
    for table <- @protected_tables do
      execute("DROP TRIGGER IF EXISTS #{table}_no_truncate ON #{table};")
      execute("DROP FUNCTION IF EXISTS prevent_#{table}_truncate();")
    end
  end
end
