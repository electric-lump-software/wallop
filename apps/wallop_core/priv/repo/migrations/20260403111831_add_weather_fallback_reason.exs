defmodule WallopCore.Repo.Migrations.AddWeatherFallbackReason do
  use Ecto.Migration

  def change do
    alter table(:draws) do
      add :weather_fallback_reason, :string
    end
  end
end
