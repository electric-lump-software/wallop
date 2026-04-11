defmodule WallopWeb.ProofBundleController do
  @moduledoc """
  Serves canonical proof bundle JSON for completed draws.

  The wallop-verify CLI and any third-party verifier consume this
  endpoint. The bytes returned must match `spec/vectors/proof-bundle.json`
  byte-for-byte for the same draw — both are produced by
  `WallopCore.ProofBundle.build/1`.

  - 200 with `application/json` for completed draws with both receipts
  - 404 for any other state
  - Immutable cache headers since the artifact never changes after a
    draw completes
  """
  use WallopWeb, :controller

  alias WallopCore.ProofBundle

  def show(conn, %{"id" => id}) do
    with {:ok, draw} <- load_draw(id),
         {:ok, json} <- ProofBundle.build(draw) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, json)
    else
      _ -> not_found(conn)
    end
  end

  defp load_draw(id) do
    case Ash.get(WallopCore.Resources.Draw, id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, draw} -> {:ok, draw}
      _ -> {:error, :not_found}
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"error":"not found"}))
  end
end
