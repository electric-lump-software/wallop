defmodule WallopWeb.ProofPdfController do
  @moduledoc """
  Serves the proof PDF for a completed draw.

  Lazy generation: on first request the PDF is rendered via ChromicPDF
  and stored in the configured `WallopWeb.ProofStorage` backend. Subsequent
  requests are served from the cache with an immutable `Cache-Control`.

  In-progress draws return 404 with a clear message — the PDF is only
  available once the draw reaches a terminal state (completed / failed /
  expired).
  """
  use WallopWeb, :controller

  alias WallopWeb.ProofPdf

  def show(conn, %{"id" => id}) do
    case load_draw(id) do
      {:ok, draw} ->
        if ProofPdf.terminal?(draw) do
          serve_pdf(conn, draw)
        else
          conn
          |> put_status(404)
          |> json(%{error: "PDF is only available once the draw has completed"})
        end

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "draw not found"})
    end
  end

  defp serve_pdf(conn, draw) do
    case ProofPdf.fetch(draw) do
      {:ok, bytes} ->
        filename = "wallop-proof-#{draw.id}.pdf"

        conn
        |> put_resp_content_type("application/pdf")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header(
          "content-disposition",
          ~s(inline; filename="#{filename}")
        )
        |> send_resp(200, bytes)

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "failed to generate PDF", detail: inspect(reason)})
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
end
