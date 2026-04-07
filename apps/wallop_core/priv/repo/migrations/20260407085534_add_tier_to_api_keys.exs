defmodule WallopCore.Repo.Migrations.AddTierToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :tier, :string
      add :monthly_draw_limit, :integer
      add :monthly_draw_count, :integer, default: 0, null: false
      add :count_reset_at, :utc_datetime_usec
    end
  end
end
