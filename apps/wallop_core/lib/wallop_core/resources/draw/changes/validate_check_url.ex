defmodule WallopCore.Resources.Draw.Changes.ValidateCheckUrl do
  @moduledoc """
  Validates the `check_url` attribute if present on the draw.

  `check_url` is the operator's own "check your ticket" page that the
  public proof page links to. Validation rules in
  `WallopCore.Resources.Draw.CheckUrl` — HTTPS-only, ≤ 2048 chars, no
  whitespace, no `javascript:` / `data:` / other dangerous schemes.
  """
  use Ash.Resource.Change

  alias WallopCore.Resources.Draw.CheckUrl

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:check_url)
    |> validate_against(changeset)
  end

  defp validate_against(nil, changeset), do: changeset

  defp validate_against(url, changeset) do
    case CheckUrl.validate(url) do
      :ok ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, field: :check_url, message: reason)
    end
  end
end
