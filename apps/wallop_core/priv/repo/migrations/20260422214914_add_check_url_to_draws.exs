defmodule WallopCore.Repo.Migrations.AddCheckUrlToDraws do
  @moduledoc """
  Add the `check_url` column to `draws` — operator's optional
  "check your ticket" page URL, rendered as an outbound link on the
  public proof page when a non-winner is checked.

  Validation (HTTPS-only, ≤ 2048 chars, no whitespace, no dangerous
  schemes) runs at the Ash layer in
  `WallopCore.Resources.Draw.Changes.ValidateCheckUrl`.
  """
  use Ecto.Migration

  def up do
    alter table(:draws) do
      add :check_url, :text, null: true
    end
  end

  def down do
    alter table(:draws) do
      remove :check_url
    end
  end
end
