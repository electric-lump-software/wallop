defmodule WallopCore.Repo.Migrations.AddOperatorSequenceToDraws do
  use Ecto.Migration

  def change do
    alter table(:draws) do
      add :operator_id, references(:operators, type: :uuid, on_delete: :restrict), null: true
      add :operator_sequence, :integer, null: true
    end

    create unique_index(:draws, [:operator_id, :operator_sequence],
             where: "operator_id IS NOT NULL",
             name: "draws_operator_sequence_unique"
           )

    create index(:draws, [:operator_id])
  end
end
