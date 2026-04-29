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

  # Schema version for the JSON keys-list response shape (spec §4.2.4).
  # A bump here is a wire-contract change for resolver-driven verifiers
  # and requires a coordinated wallop_verifier release.
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
          # `inserted_at` is the keyring entry's first-existence timestamp
          # — load-bearing for the spec §4.2.4 temporal-binding rule
          # (verifier MUST reject if `key.inserted_at > receipt.binding_timestamp`).
          # `valid_from` is deliberately NOT on the wire: it is producer-
          # side state held within ±60 s of `inserted_at` by the keyring
          # CHECK constraint, and emitting it would invite resolver
          # implementations to compare it against the receipt's binding
          # timestamp instead of `inserted_at`, reopening the V-02
          # backdating window. The canonical pin shape is the four fields
          # below.
          # `key_class: "infrastructure"` discriminates these from operator
          # keys served at `/operator/:slug/keys`. Redundant on this
          # endpoint (every row is the same class), load-bearing in the
          # `.well-known/wallop-keyring-pin.json` format where rows of
          # mixed class can coexist; emit on both endpoints so resolver
          # implementations have one canonical row shape to deserialise.
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

  # Full keyring history (current + rotated). Sorted ascending by
  # `valid_from` so consumers reading a paginated or streamed view get
  # rotations in chronological order. Rotated keys remain present
  # because historical execution receipts signed under earlier rotations
  # MUST stay verifiable for the life of 1.x per spec §4.4.
  #
  # Deliberately no `valid_from <= now` filter (cf. `current_key/0`
  # above): a row with `valid_from` in the future but inside the ±60s
  # keyring CHECK skew window appears in this list before
  # `/infrastructure/key` would serve it. That asymmetry is intentional
  # — resolver-driven verifiers benefit from pre-caching imminent
  # rotations, and the temporal-binding rule (spec §4.2.4) on the
  # consumer side compares `inserted_at` against the receipt's binding
  # timestamp, not wall-clock now.
  defp list_keys do
    InfrastructureSigningKey
    |> Ash.Query.sort(valid_from: :asc)
    |> Ash.read!(authorize?: false)
  end
end
