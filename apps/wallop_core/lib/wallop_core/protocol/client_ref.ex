defmodule WallopCore.Protocol.ClientRef do
  @moduledoc """
  Operational digests for `Draw.add_entries` idempotency (ADR-0012).

  **Operational, not protocol.** These digests are *never* signed,
  never appear in a receipt or proof bundle, and never feed
  `entry_hash` / `compute_seed`. They exist only to dedupe retries
  of `add_entries` against the `add_entries_idempotency` side table.

  This module is deliberately separate from `WallopCore.Protocol`
  (which builds signing inputs) to prevent any future PR from
  accidentally crossing the streams. A re-implementer who sees
  similar JCS-shaped construction in both modules MUST treat them
  as distinct functions with distinct test vectors. See ADR-0012
  for the receipt-invariance commitment.

  ## Constructions

      client_ref_digest =
        SHA-256("wallop-client-ref-v1\\n" || draw_id_bytes || 0x00 || client_ref_bytes)

      payload_digest =
        SHA-256("wallop-client-ref-payload-v1\\n" || JCS({
          "draw_id" => "<lowercase-hyphenated-uuid>",
          "entries" => [%{"weight" => N}, ...]   # sorted asc by weight
        }))

  - `draw_id_bytes` is the **16-byte big-endian UUID**, not the 36-byte
    ASCII form. Fixed-width encoding eliminates parser ambiguity; the
    `0x00` separator is belt-and-braces.
  - `client_ref` is plaintext at the request boundary, hashed here, and
    must be dropped by the caller before any logging or telemetry.
  - Both digests are returned as **raw 32-byte binaries**, persisted as
    `bytea`. Hex/base64/text encodings are explicitly forbidden.
  - The `payload_digest` JCS shape mirrors `Protocol.entry_hash/1` but
    differs structurally (no UUIDs in the leaves, sorted by weight not
    uuid, has a domain-separator prefix). Implementations MUST NOT
    share code with `entry_hash`.
  """

  @client_ref_domain "wallop-client-ref-v1\n"
  @payload_domain "wallop-client-ref-payload-v1\n"

  @client_ref_max_bytes 256
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc """
  Compute the client_ref digest for a `(draw_id, client_ref)` pair.

  - `draw_id` — lowercase hyphenated UUID (the 36-char ASCII form;
    decoded internally to 16 raw bytes for the digest input).
  - `client_ref` — operator-supplied opaque text. Must be a binary,
    1..#{@client_ref_max_bytes} bytes (validated here so no caller
    can bypass the cap).

  Returns the raw 32-byte SHA-256 digest. Persist as `bytea`, never
  hex-encode at the storage layer.

  Raises `ArgumentError` for invalid input.
  """
  @spec client_ref_digest(String.t(), String.t()) :: binary()
  def client_ref_digest(draw_id, client_ref)
      when is_binary(draw_id) and is_binary(client_ref) do
    draw_id_bytes = decode_uuid_to_bytes(draw_id)
    :ok = validate_client_ref(client_ref)

    :crypto.hash(
      :sha256,
      [@client_ref_domain, draw_id_bytes, <<0>>, client_ref]
    )
  end

  def client_ref_digest(draw_id, client_ref) do
    raise ArgumentError,
          "client_ref_digest: draw_id and client_ref must be binaries, got: " <>
            "#{inspect(draw_id)}, #{inspect(client_ref)}"
  end

  @doc """
  Compute the payload digest for an `add_entries` batch.

  - `draw_id` — lowercase hyphenated UUID (kept as 36-char ASCII inside
    the canonical JSON, matching the `entry_hash` shape).
  - `weights` — list of positive integers, in any order (sorted ascending
    here; ties produce byte-identical canonical objects).

  Returns the raw 32-byte SHA-256 digest.

  This deliberately differs from `WallopCore.Protocol.entry_hash/1`:
  no UUIDs in the leaves (entries don't have IDs yet at the request
  boundary), sort by weight not uuid, and a domain separator prefix.
  Implementations MUST NOT share code with `entry_hash`.

  Raises `ArgumentError` for invalid input.
  """
  @spec payload_digest(String.t(), [pos_integer()]) :: binary()
  def payload_digest(draw_id, weights) when is_binary(draw_id) and is_list(weights) do
    :ok = validate_draw_id_string(draw_id)
    Enum.each(weights, &validate_weight/1)

    sorted = Enum.sort(weights)
    encoded = Enum.map(sorted, fn w -> %{"weight" => w} end)

    canonical =
      Jcs.encode(%{
        "draw_id" => draw_id,
        "entries" => encoded
      })

    :crypto.hash(:sha256, [@payload_domain, canonical])
  end

  def payload_digest(draw_id, weights) do
    raise ArgumentError,
          "payload_digest: draw_id must be a binary and weights a list, got: " <>
            "#{inspect(draw_id)}, #{inspect(weights)}"
  end

  @doc "The maximum permitted byte length of a `client_ref` plaintext."
  @spec client_ref_max_bytes() :: pos_integer()
  def client_ref_max_bytes, do: @client_ref_max_bytes

  defp validate_client_ref(client_ref) do
    cond do
      byte_size(client_ref) == 0 ->
        raise ArgumentError, "client_ref_digest: client_ref must not be empty"

      byte_size(client_ref) > @client_ref_max_bytes ->
        raise ArgumentError,
              "client_ref_digest: client_ref exceeds " <>
                "#{@client_ref_max_bytes}-byte cap (got #{byte_size(client_ref)} bytes)"

      true ->
        :ok
    end
  end

  defp decode_uuid_to_bytes(draw_id) do
    :ok = validate_draw_id_string(draw_id)

    case Ecto.UUID.dump(draw_id) do
      {:ok, bytes} when byte_size(bytes) == 16 -> bytes
      _ -> raise ArgumentError, "client_ref_digest: invalid draw_id UUID: #{inspect(draw_id)}"
    end
  end

  defp validate_draw_id_string(draw_id) do
    if Regex.match?(@uuid_regex, draw_id) do
      :ok
    else
      raise ArgumentError,
            "client_ref protocol: draw_id must be a lowercase, hyphenated UUID, " <>
              "got: #{inspect(draw_id)}"
    end
  end

  defp validate_weight(w) when is_integer(w) and w > 0, do: :ok

  defp validate_weight(other) do
    raise ArgumentError,
          "payload_digest: weight must be a positive integer, got: #{inspect(other)}"
  end
end
