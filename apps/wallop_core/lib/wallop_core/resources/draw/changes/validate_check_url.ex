defmodule WallopCore.Resources.Draw.Changes.ValidateCheckUrl do
  @moduledoc """
  Validates `metadata.check_url` if present in the draw's metadata.

  `check_url` is the operator's own "check your ticket" page that the
  public proof page links to. Validation rules in
  `WallopCore.Resources.Draw.CheckUrl` — HTTPS-only, ≤ 2048 chars, no
  `javascript:` / `data:` / other dangerous schemes.

  `metadata` is a free-form JSON map; the only key this change cares
  about is `"check_url"`. All other keys pass through unchanged.
  """
  use Ash.Resource.Change

  alias WallopCore.Resources.Draw.CheckUrl

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> extract_check_url()
    |> validate_against(changeset)
  end

  defp extract_check_url(changeset) do
    case Ash.Changeset.get_attribute(changeset, :metadata) do
      metadata when is_map(metadata) -> Map.get(metadata, "check_url")
      _ -> nil
    end
  end

  defp validate_against(nil, changeset), do: changeset

  defp validate_against(url, changeset) do
    case CheckUrl.validate(url) do
      :ok ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :metadata,
          message: "check_url: #{reason}"
        )
    end
  end
end
