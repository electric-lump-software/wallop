defmodule WallopWeb.ProofStorage do
  @moduledoc """
  Storage backend for generated proof PDFs.

  Proof PDFs for terminal draws (completed/failed/expired) are immutable
  — the protocol data never changes once a draw transitions to a terminal
  state. We generate lazily on first request and cache forever.

  Two backends are available:

  - `WallopWeb.ProofStorage.Filesystem` — writes to a local directory.
    Useful for dev, test, and self-hosters who don't want to run an S3
    server.
  - `WallopWeb.ProofStorage.S3` — writes to any S3-compatible object
    store (Railway volumes, AWS S3, Cloudflare R2, MinIO). Configured
    via `AWS_*` env vars in production.

  The backend is chosen via application config at startup:

      config :wallop_web, :proof_storage,
        backend: WallopWeb.ProofStorage.Filesystem,
        filesystem: [root: "priv/proof_pdfs"]

  All functions accept the draw id as a binary and the PDF bytes for
  `put/2`. Get returns `{:ok, binary}` or `{:error, :not_found | term}`.
  """

  @callback put(draw_id :: String.t(), bytes :: binary()) :: :ok | {:error, term()}
  @callback get(draw_id :: String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  @callback exists?(draw_id :: String.t()) :: boolean()

  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(draw_id, bytes), do: backend().put(draw_id, bytes)

  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(draw_id), do: backend().get(draw_id)

  @spec exists?(String.t()) :: boolean()
  def exists?(draw_id), do: backend().exists?(draw_id)

  defp backend do
    Application.fetch_env!(:wallop_web, :proof_storage)[:backend]
  end
end
