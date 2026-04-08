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
  alias WallopWeb.ProofPdf.Fingerprint
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
    cond do
      not terminal?(draw) ->
        {:error, :not_terminal}

      cache_enabled?() ->
        fetch_or_generate(draw)

      true ->
        # Cache disabled — render fresh on every request, don't write
        # to storage. Used while iterating on the design so old cached
        # PDFs don't have to be hand-purged.
        generate(draw)
    end
  end

  defp fetch_or_generate(draw) do
    case ProofStorage.get(draw.id) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :not_found} -> generate_and_store(draw)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_enabled? do
    Application.get_env(:wallop_web, :proof_pdf_cache_enabled?, true)
  end

  @doc "Public so the controller can mirror this on the response Cache-Control header."
  @spec cache_enabled_for_response? :: boolean()
  def cache_enabled_for_response?, do: cache_enabled?()

  @doc """
  Force-regenerate the PDF (ignoring cache) and store the new copy
  alongside its fingerprint sidecar.

  Enforces the regeneration invariant: if a previous fingerprint exists
  for this draw, the new fingerprint must match it on every field
  except `template_revision` and `generated_at`. If anything else has
  drifted, refuse to overwrite — that means the underlying draw data
  has somehow changed, and that's a bigger bug than a layout fix.
  """
  @spec generate_and_store(map()) :: {:ok, binary()} | {:error, term()}
  def generate_and_store(draw) do
    with {:ok, fingerprint} <- build_fingerprint(draw),
         :ok <- check_regeneration_invariant(draw, fingerprint),
         encoded_fp = Fingerprint.encode(fingerprint),
         {:ok, raw_pdf} <- generate_with_fingerprint(draw, fingerprint),
         {:ok, attached_pdf} <- attach_proof_json(raw_pdf, encoded_fp),
         :ok <- ProofStorage.put_metadata(draw.id, encoded_fp),
         :ok <- ProofStorage.put(draw.id, attached_pdf) do
      {:ok, attached_pdf}
    end
  end

  @doc """
  Render the HEEx template and produce PDF bytes via Gotenberg, with
  the canonical proof.json attached. Exposed for tests that want to
  inspect the binary without touching storage.
  """
  @spec generate(map()) :: {:ok, binary()} | {:error, term()}
  def generate(draw) do
    with {:ok, fingerprint} <- build_fingerprint(draw),
         {:ok, raw_pdf} <- generate_with_fingerprint(draw, fingerprint) do
      attach_proof_json(raw_pdf, Fingerprint.encode(fingerprint))
    end
  end

  defp build_fingerprint(draw) do
    {operator, receipt} = WallopCore.OperatorInfo.for_draw(draw)
    {:ok, Fingerprint.build(draw, operator, receipt)}
  end

  defp generate_with_fingerprint(draw, _fingerprint) do
    entries = WallopCore.Entries.load_for_draw(draw.id)
    {operator, receipt} = WallopCore.OperatorInfo.for_draw(draw)
    winners = WallopCore.Proof.anonymise_results(draw.results || [])

    assigns = %{
      draw: draw,
      entries: entries,
      operator: operator,
      receipt: receipt,
      winners: winners,
      public_url: public_url(draw.id),
      generated_at: DateTime.utc_now()
    }

    html =
      assigns
      |> ProofPdfHTML.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    render_via_gotenberg(html, logo_bytes())
  end

  defp check_regeneration_invariant(draw, new_fingerprint) do
    case ProofStorage.get_metadata(draw.id) do
      {:ok, prior_json} ->
        with {:ok, prior_fingerprint} <- Jason.decode(prior_json),
             :ok <- Fingerprint.compare(prior_fingerprint, new_fingerprint) do
          :ok
        else
          {:error, {:fingerprint_mismatch, fields}} ->
            Logger.error(
              "ProofPdf: refusing to regenerate #{draw.id}, fingerprint drift on: #{inspect(fields)}"
            )

            {:error, {:fingerprint_mismatch, fields}}

          {:error, reason} ->
            Logger.warning(
              "ProofPdf: prior fingerprint for #{draw.id} unparseable (#{inspect(reason)}), continuing"
            )

            :ok
        end

      {:error, :not_found} ->
        # First generation for this draw — nothing to compare against.
        :ok

      {:error, reason} ->
        Logger.warning(
          "ProofPdf: could not read prior fingerprint for #{draw.id} (#{inspect(reason)}), continuing"
        )

        :ok
    end
  end

  @doc """
  Attach the canonical proof.json fingerprint to a PDF as an embedded
  file using the qpdf command-line tool.

  qpdf is the standard PDF object-stream manipulator on Linux; it has
  to be installed in the runtime image (`apt-get install qpdf`). The
  call writes both inputs to a temp dir, runs qpdf, reads the output,
  and cleans up.
  """
  @spec attach_proof_json(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def attach_proof_json(pdf_bytes, json_bytes)
      when is_binary(pdf_bytes) and is_binary(json_bytes) do
    tmp_dir = System.tmp_dir!() |> Path.join("wallop_pdf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    input_path = Path.join(tmp_dir, "input.pdf")
    output_path = Path.join(tmp_dir, "output.pdf")
    json_path = Path.join(tmp_dir, "proof.json")

    try do
      File.write!(input_path, pdf_bytes)
      File.write!(json_path, json_bytes)

      with :ok <- run_qpdf_attach(input_path, json_path, output_path),
           :ok <- verify_attachment_present(output_path) do
        File.read(output_path)
      end
    after
      # Use non-bang to avoid masking the original error if cleanup fails
      File.rm_rf(tmp_dir)
    end
  end

  defp run_qpdf_attach(input_path, json_path, output_path) do
    args = [
      "--add-attachment",
      json_path,
      "--mimetype=application/json",
      "--",
      input_path,
      output_path
    ]

    case System.cmd("qpdf", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        Logger.error("ProofPdf: qpdf attach failed (exit #{exit_code}): #{output}")
        {:error, {:qpdf_failed, exit_code, output}}
    end
  end

  # Paranoid post-attach check: re-run qpdf to list attachments and
  # confirm proof.json is actually present in the output. Catches qpdf
  # version skew, silent truncation, and "0 exit but no attachment"
  # edge cases. One extra fork per PDF is cheap; shipping a
  # fingerprint-less PDF claiming to be fingerprinted is not.
  defp verify_attachment_present(pdf_path) do
    case System.cmd("qpdf", ["--list-attachments", pdf_path], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "proof.json") do
          :ok
        else
          Logger.error(
            "ProofPdf: qpdf reported attach success but proof.json missing from output: #{output}"
          )

          {:error, :qpdf_attachment_missing}
        end

      {output, exit_code} ->
        Logger.error("ProofPdf: qpdf list-attachments failed (exit #{exit_code}): #{output}")
        {:error, {:qpdf_list_failed, exit_code, output}}
    end
  end

  @doc """
  POST an HTML document to the sidecar Gotenberg service and return the
  PDF bytes. Gotenberg's `/forms/chromium/convert/html` endpoint takes a
  multipart form with an `index.html` file (plus any referenced assets);
  we only need the one file.
  """
  @spec render_via_gotenberg(binary(), binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def render_via_gotenberg(html, logo \\ nil) when is_binary(html) do
    url = gotenberg_url() <> "/forms/chromium/convert/html"

    files = [
      {html, filename: "index.html", content_type: "text/html"}
    ]

    files =
      case logo do
        nil ->
          files

        bytes when is_binary(bytes) ->
          files ++ [{bytes, filename: "logo.png", content_type: "image/png"}]
      end

    form_multipart = Enum.map(files, fn file -> {:files, file} end)

    case Req.post(url,
           form_multipart: form_multipart,
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

  defp logo_bytes do
    path = Application.app_dir(:wallop_web, "priv/static/images/logo-cropped@2x.png")

    case File.read(path) do
      {:ok, bytes} ->
        bytes

      {:error, reason} ->
        Logger.warning("ProofPdf: could not read logo at #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp public_url(draw_id) do
    base = Application.get_env(:wallop_web, :public_base_url, "https://wallop.run")
    "#{base}/proof/#{draw_id}"
  end
end
