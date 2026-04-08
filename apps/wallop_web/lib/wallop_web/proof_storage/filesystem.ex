defmodule WallopWeb.ProofStorage.Filesystem do
  @moduledoc """
  Local-filesystem backend for `WallopWeb.ProofStorage`.

  Writes PDFs to a single directory, one file per draw id. Suitable for
  dev, test, and self-hosters. Not suitable for a horizontally-scaled
  deployment where multiple nodes need to serve the same cache — use the
  S3 backend for that.
  """
  @behaviour WallopWeb.ProofStorage

  @impl true
  def put(draw_id, bytes) do
    path = path_for(draw_id)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, bytes)
  end

  @impl true
  def get(draw_id) do
    case File.read(path_for(draw_id)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(draw_id) do
    File.exists?(path_for(draw_id))
  end

  @impl true
  def put_metadata(draw_id, json) do
    path = metadata_path_for(draw_id)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, json)
  end

  @impl true
  def get_metadata(draw_id) do
    case File.read(metadata_path_for(draw_id)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_for(draw_id) do
    Path.join(root(), "#{draw_id}.pdf")
  end

  defp metadata_path_for(draw_id) do
    Path.join(root(), "#{draw_id}.json")
  end

  defp root do
    Application.fetch_env!(:wallop_web, :proof_storage)[:filesystem][:root]
  end
end
