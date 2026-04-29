defmodule WallopCore.Protocol.Pin do
  @moduledoc """
  Signed keyring pin per spec §4.2.4 — the trust artefact for tier-1
  attributable verification.

  A pin commits, under the wallop infrastructure signing key, to the
  current set of an operator's signing keys. Verifiers anchored against
  a bundled wallop infrastructure public key can use the pin to confirm
  that an operator's live keyring matches what wallop has attested.

  This module is the canonical-bytes producer. It does not load anything
  from the database; callers pass in the keyring rows and the signing
  key. The HTTP endpoint sits in `WallopWeb.OperatorController`.

  ## Wire envelope

      {
        "schema_version": "1",
        "operator_slug": "...",
        "keys": [
          { "key_id": "...", "public_key_hex": "...", "key_class": "operator" },
          ...
        ],
        "published_at": "RFC 3339 microsecond UTC",
        "infrastructure_signature": "lowercase 128-character hex"
      }

  ## Signature construction

      signature = Ed25519.sign(
        "wallop-pin-v1\\n" <> JCS({schema_version, operator_slug, keys[], published_at}),
        infrastructure_private_key
      )

  The `infrastructure_signature` field is excluded from the JCS pre-image.
  Verifiers reconstruct the pre-image by parsing the envelope, removing
  `infrastructure_signature`, and JCS-canonicalising what's left.

  ## Producer obligations

  - `keys[]` MUST be sorted by `key_id` ASCII byte-order ascending.
  - `keys[]` MUST be non-empty. A pin with no keys cannot serve its purpose.
  - Every entry's `key_class` MUST be the literal string `"operator"`.
    Infrastructure keys are anchored separately via the verifier-bundled
    trust anchor and have no place in the pin.
  - `published_at` MUST be the producer's wall-clock UTC immediately
    before computing the signature pre-image. The caller is responsible
    for supplying a fresh value on each sign — this module does not stamp.
  - The producer MUST NOT sign with an infrastructure key whose
    `revoked_at` is set, regardless of any verifier-side grace window.
    This module does not check `revoked_at`; the caller does.
  """

  @schema_version "1"
  @domain_separator "wallop-pin-v1\n"

  @doc """
  Schema version literal. Spec §4.2.4 closed-set field.
  """
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  Domain separator bytes prepended to the JCS pre-image before signing.
  Frozen at the §4.2.4 spec; rotating it requires a new schema_version.
  """
  @spec domain_separator() :: binary()
  def domain_separator, do: @domain_separator

  @doc """
  Build the canonical JCS pre-image bytes for a pin envelope.

  The returned bytes are what gets signed (after domain-separator
  prepending). They are also the bytes a verifier must reconstruct
  by stripping the `infrastructure_signature` field from the parsed
  envelope.

  Caller passes:
    * `:operator_slug` — string
    * `:keys` — list of `{key_id: String.t(), public_key: <<_::32-bytes>>}`
      maps. Order is normalised here (ascending by `key_id`); caller may
      pass any order. The module enforces non-emptiness.
    * `:published_at` — `%DateTime{}` with microsecond precision

  Raises `ArgumentError` on `keys: []` or any malformed row.
  """
  @spec build_payload(map()) :: {payload_jcs :: binary(), envelope :: map()}
  def build_payload(%{
        operator_slug: operator_slug,
        keys: keys,
        published_at: %DateTime{} = published_at
      })
      when is_list(keys) do
    if keys == [] do
      raise ArgumentError, "Pin.build_payload: keys[] MUST be non-empty"
    end

    serialised_keys = serialise_keys(keys)

    envelope = %{
      "schema_version" => @schema_version,
      "operator_slug" => to_string(operator_slug),
      "keys" => serialised_keys,
      "published_at" => WallopCore.Time.to_rfc3339_usec(published_at)
    }

    {Jcs.encode(envelope), envelope}
  end

  @doc """
  Sign a pin pre-image with an Ed25519 private key.

  Prepends the domain separator before passing to `:crypto`. Returns the
  raw 64-byte signature.
  """
  @spec sign(binary(), binary()) :: binary()
  def sign(payload_jcs, private_key)
      when is_binary(payload_jcs) and byte_size(private_key) == 32 do
    :crypto.sign(:eddsa, :none, @domain_separator <> payload_jcs, [private_key, :ed25519])
  end

  @doc """
  Verify an Ed25519 signature over a pin pre-image.

  Prepends the domain separator before passing to `:crypto`. Returns
  `true` only if both the bytes and the public key check out.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(payload_jcs, signature, public_key)
      when is_binary(payload_jcs) and byte_size(signature) == 64 and
             byte_size(public_key) == 32 do
    :crypto.verify(
      :eddsa,
      :none,
      @domain_separator <> payload_jcs,
      signature,
      [public_key, :ed25519]
    )
  end

  @doc """
  Wrap a payload envelope and signature into the wire JSON shape.

  Adds the `infrastructure_signature` field as lowercase 128-character
  hex. The returned map is JSON-serialisable as-is.
  """
  @spec build_envelope(map(), binary()) :: map()
  def build_envelope(envelope, signature)
      when is_map(envelope) and byte_size(signature) == 64 do
    Map.put(envelope, "infrastructure_signature", Base.encode16(signature, case: :lower))
  end

  # Validate every keyring row, normalise to wire shape, sort ascending
  # by key_id (ASCII byte-order, equivalent to lexicographic on lowercase
  # hex per the §4.2.4 fingerprint rule).
  defp serialise_keys(keys) do
    keys
    |> Enum.map(&serialise_key/1)
    |> Enum.sort_by(& &1["key_id"])
  end

  defp serialise_key(%{key_id: key_id, public_key: public_key})
       when is_binary(key_id) and byte_size(public_key) == 32 do
    %{
      "key_id" => key_id,
      "public_key_hex" => Base.encode16(public_key, case: :lower),
      "key_class" => "operator"
    }
  end

  defp serialise_key(other) do
    raise ArgumentError,
          "Pin.build_payload: invalid keyring row " <>
            "(want %{key_id: String.t(), public_key: <<_::32-bytes>>}), got: " <>
            inspect(other)
  end
end
