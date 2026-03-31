defmodule WallopCore.Repo.Migrations.AddDrawsIndexes do
  use Ecto.Migration

  def change do
    create index(:draws, [:api_key_id])
    create index(:draws, [:api_key_id, "inserted_at DESC"], name: :draws_api_key_id_inserted_at_index)
  end
end
