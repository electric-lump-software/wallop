defmodule WallopCore.Repo.Migrations.AddUpdatedAtToOperators do
  use Ecto.Migration

  def change do
    alter table(:operators) do
      add :updated_at, :utc_datetime_usec
    end

    execute(
      "UPDATE operators SET updated_at = inserted_at WHERE updated_at IS NULL",
      ""
    )

    alter table(:operators) do
      modify :updated_at, :utc_datetime_usec, null: false
    end
  end
end
