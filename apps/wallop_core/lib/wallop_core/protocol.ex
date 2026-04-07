defmodule WallopCore.Protocol do
  @moduledoc """
  Wallop commit-reveal protocol operations.

  Entry hashing (§2.1) and seed computation (§2.3) as defined in
  docs/specs/fair-pick-protocol.md.
  """

  @doc """
  Compute the entry hash for a list of entries.

  Returns `{hex_hash, jcs_string}` where:
  - `hex_hash` is the 64-char lowercase hex SHA256 of the JCS bytes
  - `jcs_string` is the canonical JSON for verification/debugging
  """
  @spec entry_hash([%{id: String.t(), weight: pos_integer()}]) :: {String.t(), String.t()}
  def entry_hash(entries) do
    sorted = Enum.sort_by(entries, & &1.id)

    json_data = %{
      "entries" => Enum.map(sorted, fn e -> %{"id" => e.id, "weight" => e.weight} end)
    }

    jcs_string = Jcs.encode(json_data)
    hash = :crypto.hash(:sha256, jcs_string) |> Base.encode16(case: :lower)

    {hash, jcs_string}
  end

  @doc """
  Compute the draw seed from entropy sources.

  With 3 arguments (entry_hash, drand_randomness, weather_value): uses both
  drand and weather entropy.

  With 2 arguments (entry_hash, drand_randomness): drand-only fallback. The
  weather_value key is omitted entirely from the JCS JSON, providing implicit
  domain separation (the two arities can never produce the same seed).

  Returns `{seed_bytes, jcs_string}` where:
  - `seed_bytes` is the raw 32-byte SHA256 (passed directly to FairPick.draw/3)
  - `jcs_string` is the canonical JSON for the proof record
  """
  @spec compute_seed(String.t(), String.t(), String.t()) :: {<<_::256>>, String.t()}
  def compute_seed(entry_hash, drand_randomness, weather_value) do
    json_data = %{
      "drand_randomness" => drand_randomness,
      "entry_hash" => entry_hash,
      "weather_value" => weather_value
    }

    jcs_string = Jcs.encode(json_data)
    seed_bytes = :crypto.hash(:sha256, jcs_string)

    {seed_bytes, jcs_string}
  end

  @spec compute_seed(String.t(), String.t()) :: {<<_::256>>, String.t()}
  def compute_seed(entry_hash, drand_randomness) do
    json_data = %{
      "drand_randomness" => drand_randomness,
      "entry_hash" => entry_hash
    }

    jcs_string = Jcs.encode(json_data)
    seed_bytes = :crypto.hash(:sha256, jcs_string)

    {seed_bytes, jcs_string}
  end

  @receipt_schema_version "1"

  @doc """
  Build the canonical JCS payload bytes for an operator commitment receipt.

  Pure function — no IO, no time. Caller passes everything in.

  Field set is fixed and sorted by JCS:
  `commitment_hash`, `draw_id`, `entry_hash`, `locked_at`, `operator_id`,
  `operator_slug`, `schema_version`, `sequence`, `signing_key_id`.

  `locked_at` must be a `DateTime` with microsecond precision; the caller is
  responsible for capturing it once at lock time and not re-stamping.
  """
  @spec build_receipt_payload(map()) :: binary()
  def build_receipt_payload(%{
        operator_id: operator_id,
        operator_slug: operator_slug,
        sequence: sequence,
        draw_id: draw_id,
        commitment_hash: commitment_hash,
        entry_hash: entry_hash,
        locked_at: %DateTime{} = locked_at,
        signing_key_id: signing_key_id
      }) do
    Jcs.encode(%{
      "commitment_hash" => commitment_hash,
      "draw_id" => draw_id,
      "entry_hash" => entry_hash,
      "locked_at" => DateTime.to_iso8601(locked_at),
      "operator_id" => operator_id,
      "operator_slug" => to_string(operator_slug),
      "schema_version" => @receipt_schema_version,
      "sequence" => sequence,
      "signing_key_id" => signing_key_id
    })
  end

  @doc """
  Sign a receipt payload with an Ed25519 private key.

  Returns the raw 64-byte signature. Uses OTP `:crypto` directly — no
  third-party Ed25519 library.
  """
  @spec sign_receipt(binary(), binary()) :: binary()
  def sign_receipt(payload_jcs, private_key)
      when is_binary(payload_jcs) and byte_size(private_key) == 32 do
    :crypto.sign(:eddsa, :none, payload_jcs, [private_key, :ed25519])
  end

  @doc """
  Verify an Ed25519 signature over a receipt payload.
  """
  @spec verify_receipt(binary(), binary(), binary()) :: boolean()
  def verify_receipt(payload_jcs, signature, public_key)
      when is_binary(payload_jcs) and byte_size(signature) == 64 and
             byte_size(public_key) == 32 do
    :crypto.verify(:eddsa, :none, payload_jcs, signature, [public_key, :ed25519])
  end

  @doc """
  Compute the short key_id for an Ed25519 public key.

  First 8 lowercase hex characters of `sha256(public_key)`. Embedded in every
  signed receipt so verifiers can resolve which historical key was used after
  rotation.
  """
  @spec key_id(binary()) :: String.t()
  def key_id(public_key) when byte_size(public_key) == 32 do
    :sha256
    |> :crypto.hash(public_key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc """
  Compute the RFC 6962-style binary Merkle root over a list of leaves.

  - Empty list → `sha256(<<>>)` sentinel
  - Single leaf → `sha256(<<0>> <> leaf)`
  - Internal nodes → `sha256(<<1>> <> left <> right)`
  - Odd-length levels duplicate the last node (RFC 6962 §2.1)

  Returns the 32-byte root.
  """
  @spec merkle_root([binary()]) :: <<_::256>>
  def merkle_root([]), do: :crypto.hash(:sha256, <<>>)

  def merkle_root(leaves) when is_list(leaves) do
    leaves
    |> Enum.map(fn leaf -> :crypto.hash(:sha256, <<0>> <> leaf) end)
    |> reduce_levels()
  end

  defp reduce_levels([root]), do: root

  defp reduce_levels(nodes) do
    nodes
    |> pair_up()
    |> Enum.map(fn {l, r} -> :crypto.hash(:sha256, <<1>> <> l <> r) end)
    |> reduce_levels()
  end

  defp pair_up([]), do: []
  defp pair_up([single]), do: [{single, single}]
  defp pair_up([a, b | rest]), do: [{a, b} | pair_up(rest)]
end
