defmodule WallopWeb.RetiredDraw do
  @moduledoc """
  Draws locked under the retired forecast-weather method.

  A draw is retired when it has no lock schema (`lock_schema_version` is
  nil) and has left open by any route but expiry. Every lock now carries
  lock schema 6, and the database refuses any other way out of open, so
  that test is exact and needs no query. It also covers the old draws that
  have a lock receipt but no execution receipt. An open or expired draw is
  never retired and keeps its normal page.

  Every proof route answers a retired draw exactly as it answers an
  unknown id. Current tools don't check these draws, so no page here shows
  their winners, seed or a check. Their signed receipts stay available,
  byte for byte, at `/operator/:slug/receipts/:seq` and
  `/operator/:slug/executions/:seq`, because the transparency anchors
  commit to those bytes.
  """

  alias WallopCore.Resources.Draw

  @doc """
  True when `draw` has no lock schema and is neither open nor expired.

  Fails safe: a draw whose `lock_schema_version` or `status` isn't loaded
  raises rather than passing as not retired.
  """
  @spec retired?(map()) :: boolean()
  def retired?(%{lock_schema_version: schema, status: status})
      when not is_struct(schema, Ash.NotLoaded) and not is_struct(status, Ash.NotLoaded) do
    is_nil(schema) and status not in [:open, :expired]
  end

  def retired?(draw) do
    raise ArgumentError,
          "RetiredDraw.retired?/1 needs lock_schema_version and status loaded, got: " <>
            inspect(Map.take(draw, [:id, :lock_schema_version, :status]))
  end

  @doc """
  The draw a public proof route may show: `{:ok, draw}`, or
  `{:error, :not_found}` for a draw that doesn't exist or is retired.
  """
  @spec fetch(String.t()) :: {:ok, Draw.t()} | {:error, :not_found}
  def fetch(id) do
    case Ash.get(Draw, id, domain: WallopCore.Domain, authorize?: false) do
      {:ok, draw} -> if retired?(draw), do: {:error, :not_found}, else: {:ok, draw}
      _ -> {:error, :not_found}
    end
  end
end
