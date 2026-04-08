defmodule WallopWeb.ProofPdf do
  @moduledoc """
  Generate certificate-style proof PDFs for terminal draws.

  Renders a dedicated HEEx template with print-specific CSS, POSTs the
  HTML to a sidecar Gotenberg service (headless Chromium wrapped in a
  stateless HTTP API — https://gotenberg.dev), and receives the PDF
  bytes. Terminal draws only — in-progress draws return
  `{:error, :not_terminal}`.

  Generation is lazy: on first request `generate_and_store/1` computes
  the PDF, stores it in the configured `WallopWeb.ProofStorage` backend,
  and returns the bytes. Subsequent requests are served from the cache
  via `WallopWeb.ProofStorage.get/1`.

  Gotenberg runs as a separate Railway service (or `docker run` locally).
  wallop reaches it via `GOTENBERG_URL` (e.g.
  `http://gotenberg.railway.internal:3000`) on the internal network.
  """

  require Logger

  alias Phoenix.HTML.Safe
  alias WallopWeb.ProofPdfHTML
  alias WallopWeb.ProofStorage

  @terminal_statuses [:completed, :failed, :expired]

  @spec terminal?(map()) :: boolean()
  def terminal?(%{status: status}), do: status in @terminal_statuses

  @doc """
  Fetch the PDF for a draw. Generates lazily on first access, caches
  forever in the configured storage backend.
  """
  @spec fetch(map()) :: {:ok, binary()} | {:error, :not_terminal | term()}
  def fetch(draw) do
    if terminal?(draw) do
      fetch_or_generate(draw)
    else
      {:error, :not_terminal}
    end
  end

  defp fetch_or_generate(draw) do
    case ProofStorage.get(draw.id) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :not_found} -> generate_and_store(draw)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Force-regenerate the PDF (ignoring cache) and store the new copy.
  """
  @spec generate_and_store(map()) :: {:ok, binary()} | {:error, term()}
  def generate_and_store(draw) do
    with {:ok, bytes} <- generate(draw),
         :ok <- ProofStorage.put(draw.id, bytes) do
      {:ok, bytes}
    end
  end

  @doc """
  Render the HEEx template and produce PDF bytes via ChromicPDF. Exposed
  for tests that want to inspect the binary without touching storage.
  """
  @spec generate(map()) :: {:ok, binary()} | {:error, term()}
  def generate(draw) do
    entries = WallopCore.Entries.load_for_draw(draw.id)
    {operator, receipt} = WallopCore.OperatorInfo.for_draw(draw)

    assigns = %{
      draw: draw,
      entries: entries,
      operator: operator,
      receipt: receipt,
      public_url: public_url(draw.id),
      generated_at: DateTime.utc_now()
    }

    html =
      assigns
      |> ProofPdfHTML.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    render_via_gotenberg(html)
  end

  @doc """
  POST an HTML document to the sidecar Gotenberg service and return the
  PDF bytes. Gotenberg's `/forms/chromium/convert/html` endpoint takes a
  multipart form with an `index.html` file (plus any referenced assets);
  we only need the one file.
  """
  @spec render_via_gotenberg(binary()) :: {:ok, binary()} | {:error, term()}
  def render_via_gotenberg(html) when is_binary(html) do
    url = gotenberg_url() <> "/forms/chromium/convert/html"

    case Req.post(url,
           form_multipart: [
             files: {html, filename: "index.html", content_type: "text/html"}
           ],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: pdf}} ->
        {:ok, pdf}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("ProofPdf: gotenberg returned #{status}: #{inspect(body)}")
        {:error, {:gotenberg_http_error, status}}

      {:error, reason} ->
        Logger.error("ProofPdf: gotenberg request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp gotenberg_url do
    Application.get_env(:wallop_web, :gotenberg_url, "http://localhost:3000")
  end

  defp public_url(draw_id) do
    base = Application.get_env(:wallop_web, :public_base_url, "https://wallop.run")
    "#{base}/proof/#{draw_id}"
  end
end
