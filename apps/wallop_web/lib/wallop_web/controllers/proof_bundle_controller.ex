defmodule WallopWeb.ProofBundleController do
  @moduledoc """
  Serves canonical proof bundle JSON for completed draws.

  The wallop-verify CLI and any third-party verifier consume this
  endpoint. The bytes returned must match `spec/vectors/proof-bundle.json`
  byte-for-byte for the same draw — both are produced by
  `WallopCore.ProofBundle.build/1`.

  Status codes:
  - 200: completed draw with both receipts and signing keys
  - 404: draw not found, or draw not yet completed
  - 500: completed draw with a broken proof chain (missing receipts or
    keys) — this should not happen in production but is surfaced
    explicitly rather than masquerading as a 404, mirroring the red
    warning the operator panel shows for the same condition

  Immutable cache headers are only set on the 200 path.
  """
  use WallopWeb, :controller

  alias WallopCore.ProofBundle

  def show(conn, %{"id" => id}) do
    case load_draw(id) do
      {:ok, draw} -> render_bundle(conn, draw)
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp render_bundle(conn, draw) do
    case ProofBundle.build(draw) do
      {:ok, json} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, json)

      {:error, :draw_not_completed} ->
        not_found(conn)

      {:error, reason}
      when reason in [
             :missing_lock_receipt,
             :missing_execution_receipt,
             :missing_operator_key,
             :missing_infrastructure_key
           ] ->
        proof_chain_incomplete(conn, reason)
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

  defp proof_chain_incomplete(conn, reason) do
    body =
      Jason.encode!(%{
        "error" => "proof_chain_incomplete",
        "detail" => to_string(reason)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, body)
  end
end
