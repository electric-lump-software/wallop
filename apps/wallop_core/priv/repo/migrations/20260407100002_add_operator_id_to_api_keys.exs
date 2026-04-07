defmodule WallopCore.Repo.Migrations.AddOperatorIdToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :operator_id, references(:operators, type: :uuid, on_delete: :restrict), null: true
    end

    create index(:api_keys, [:operator_id])
  end
end
