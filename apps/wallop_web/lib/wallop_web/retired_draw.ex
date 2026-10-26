defmodule WallopWeb.RetiredDraw do
  @moduledoc """
  Draws locked under the retired forecast-weather method.

  A draw is retired when it has no lock schema (`lock_schema_version` is
  NULL) and a stored lock receipt: it was locked, but not under lock
  schema 6. Every lock now carries lock schema 6, so no new draw can be
  retired. An open or expired draw has no lock receipt, so it is never
  retired and keeps its normal page.

  Every proof route treats a retired draw as one that doesn't exist, with
  the same response, so the two can't be told apart. Current tools don't
  verify these draws, so no page here shows their winners, seed or a check.
  Their signed receipts stay available, byte for byte, at
  `/operator/:slug/receipts/:seq` and `/operator/:slug/executions/:seq`,
  because the transparency anchors commit to those bytes.
  """

  require Ash.Query

  alias WallopCore.Resources.{Draw, OperatorReceipt}

  @doc "True when `draw` has no lock schema and a stored lock receipt."
  @spec retired?(Draw.t()) :: boolean()
  def retired?(%{lock_schema_version: nil, id: id}) do
    OperatorReceipt
    |> Ash.Query.filter(draw_id == ^id)
    |> Ash.exists?(authorize?: false)
  end

  def retired?(_draw), do: false

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
