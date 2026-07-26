defmodule WallopCore.Repo.Migrations.UpdateObanToV14 do
  use Ecto.Migration

  # Oban 2.23 requires schema version 14; the initial migration installed 12.
  # Consuming apps that run wallop_core against their own Oban prefix need the
  # equivalent migration in their own repo — see MIGRATING.md.
  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 12)
  end
end
