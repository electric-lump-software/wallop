defmodule WallopWeb.ProofStorage.S3 do
  @moduledoc """
  S3-compatible backend for `WallopWeb.ProofStorage`.

  Works against any S3-compatible endpoint: Railway volumes, AWS S3,
  Cloudflare R2, MinIO. Configure via application env and the `AWS_*`
  env vars picked up by `ex_aws` in `runtime.exs`.
  """
  @behaviour WallopWeb.ProofStorage

  alias ExAws.S3

  @impl true
  def put(draw_id, bytes) do
    bucket()
    |> S3.put_object(key_for(draw_id), bytes, content_type: "application/pdf")
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(draw_id) do
    bucket()
    |> S3.get_object(key_for(draw_id))
    |> ExAws.request()
    |> case do
      {:ok, %{body: bytes}} -> {:ok, bytes}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(draw_id) do
    bucket()
    |> S3.head_object(key_for(draw_id))
    |> ExAws.request()
    |> case do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp key_for(draw_id), do: "#{prefix()}/#{draw_id}.pdf"

  defp bucket do
    Application.fetch_env!(:wallop_web, :proof_storage)[:s3][:bucket]
  end

  defp prefix do
    Application.fetch_env!(:wallop_web, :proof_storage)[:s3][:prefix]
  end
end
