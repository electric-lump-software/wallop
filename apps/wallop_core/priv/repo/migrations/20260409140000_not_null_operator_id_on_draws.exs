defmodule WallopCore.Repo.Migrations.NotNullOperatorIdOnDraws do
  @moduledoc """
  Enforce NOT NULL on draws.operator_id at the database level.

  The application already rejects draws without operators (RequireOperator
  validation, 0.14.0). This mirrors the invariant in the schema so it
  can't be bypassed by direct SQL.

  Pre-condition: all rows with operator_id IS NULL must be deleted
  before running this migration.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE draws ALTER COLUMN operator_id SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE draws ALTER COLUMN operator_id DROP NOT NULL")
  end
end
