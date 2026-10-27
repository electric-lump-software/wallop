defmodule WallopWeb.InfrastructureController do
  @moduledoc """
  Public endpoints for the wallop infrastructure Ed25519 public keys.

  Third-party verifiers need these to verify execution receipts and
  transparency anchors. The infra key is wallop-wide (not per-operator)
  and rotated manually via `mix wallop.rotate_infrastructure_key`.

  Two endpoints:

  * `GET /infrastructure/key` — returns the *current* signing key as raw
    32-byte Ed25519 public-key bytes with `x-wallop-key-id` header.
    Stable since the early CLI; preserved for callers that already
    consume it. Returns only the active rotation slot.

  * `GET /infrastructure/keys` — returns the *full* infrastructure key
    history as JSON in the canonical shape consumed by resolver-driven
    verifiers per spec §4.2.4. Mirrors `/operator/:slug/keys`'s response
    shape with `key_class: "infrastructure"`. Includes rotated keys so
    historical execution receipts and anchors remain verifiable.
  """
  use WallopWeb, :controller

  require Ash.Query

  alias WallopCore.Resources.InfrastructureSigningKey

  @keys_response_schema_version "1"

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

  def keys_index(conn, _params) do
    keys = list_keys()

    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(%{
      schema_version: @keys_response_schema_version,
      keys:
        Enum.map(keys, fn k ->
          %{
            key_id: k.key_id,
            public_key_hex: Base.encode16(k.public_key, case: :lower),
            inserted_at: k.inserted_at,
            key_class: "infrastructure"
          }
        end)
    })
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

  defp list_keys do
    InfrastructureSigningKey
    |> Ash.Query.sort(valid_from: :asc)
    |> Ash.read!(authorize?: false)
  end
end
