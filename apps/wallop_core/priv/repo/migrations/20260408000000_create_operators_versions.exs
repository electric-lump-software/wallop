defmodule WallopCore.Repo.Migrations.CreateOperatorsVersions do
  use Ecto.Migration

  def change do
    create table(:operators_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :version_action_type, :string, null: false
      add :version_action_name, :string, null: false
      add :version_action_inputs, :map, null: false, default: %{}
      add :version_source_id, references(:operators, type: :uuid, on_delete: :restrict), null: false
      add :changes, :map
      add :version_inserted_at, :utc_datetime_usec, null: false
      add :version_updated_at, :utc_datetime_usec, null: false
    end

    create index(:operators_versions, [:version_source_id])
    create index(:operators_versions, [:version_inserted_at])
  end
end
