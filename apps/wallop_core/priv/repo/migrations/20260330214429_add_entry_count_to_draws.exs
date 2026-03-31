defmodule WallopCore.Repo.Migrations.AddEntryCountToDraws do
  use Ecto.Migration

  def change do
    alter table(:draws) do
      add :entry_count, :integer, null: false, default: 0
    end
  end
end
