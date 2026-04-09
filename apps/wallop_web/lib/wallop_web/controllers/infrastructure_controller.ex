defmodule WallopWeb.InfrastructureController do
  @moduledoc """
  Public endpoint for the wallop infrastructure Ed25519 public key.

  Third-party verifiers need this to verify execution receipts. The infra
  key is wallop-wide (not per-operator) and rotated manually via
  `mix wallop.rotate_infrastructure_key`.
  """
  use WallopWeb, :controller

  require Ash.Query

  alias WallopCore.Resources.InfrastructureSigningKey

  def key_pub(conn, _params) do
    case current_key() do
      {:ok, key} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("cache-control", "public, max-age=300")
        |> put_resp_header("x-wallop-key-id", key.key_id)
        |> send_resp(200, key.public_key)

      :error ->
        conn
        |> put_status(404)
        |> json(%{error: "not found"})
    end
  end

  defp current_key do
    now = DateTime.utc_now()

    InfrastructureSigningKey
    |> Ash.Query.filter(valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [key] -> {:ok, key}
      [] -> :error
    end
  end
end
