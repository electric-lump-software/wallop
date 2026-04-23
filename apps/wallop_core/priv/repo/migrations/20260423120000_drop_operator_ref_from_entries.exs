defmodule WallopCore.Repo.Migrations.DropOperatorRefFromEntries do
  @moduledoc """
  Drop the `operator_ref` column from `entries`.

  Operator-supplied reference strings no longer live in wallop_core.
  Callers that need `uuid ↔ their-own-id` mapping capture it from the
  `add_entries` response (UUIDs returned in submission order) and store
  it in their own encrypted-at-rest table.
  """
  use Ecto.Migration

  def up do
    alter table(:entries) do
      remove :operator_ref
    end
  end

  def down do
    alter table(:entries) do
      add :operator_ref, :text, null: true
    end
  end
end
