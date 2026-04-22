defmodule WallopCore.Protocol do
  @moduledoc """
  Wallop commit-reveal protocol operations.

  Entry hashing (§2.1) and seed computation (§2.3) as defined in
  `spec/protocol.md`.
  """

  @doc """
  Compute the entry hash for a draw.

  Canonical form:

      SHA-256(JCS(%{
        "draw_id" => "<lowercase-hyphenated-uuidv4>",
        "entries" => [
          %{"operator_ref" => ?, "uuid" => ..., "weight" => N},
          ...
        ]
      }))

  Entries are sorted ascending by `uuid` (binary lex). `operator_ref` is
  omitted from the entry object when nil or the empty string. `weight` must
  be a positive integer. All UUIDs must be lowercase, hyphenated RFC 4122
  form (36 chars, no braces, no URN prefix). `operator_ref` must be ≤ 64
  bytes and contain no control characters
  (U+0000–U+001F, U+007F, U+2028, U+2029).

  Returns `{hex_hash, jcs_string}`:
  - `hex_hash` — 64-char lowercase hex SHA-256 of the JCS bytes
  - `jcs_string` — the canonical JSON (for verification / debugging)

  Violations raise `ArgumentError`. See `spec/protocol.md` §2.1.
  """
  @spec entry_hash({String.t(), [map()]}) :: {String.t(), String.t()}
  def entry_hash({draw_id, entries}) when is_binary(draw_id) and is_list(entries) do
    :ok = validate_draw_id(draw_id)
    Enum.each(entries, &validate_entry/1)

    encoded_entries =
      entries
      |> Enum.sort_by(& &1.uuid)
      |> Enum.map(&encode_entry/1)

    json_data = %{
      "draw_id" => draw_id,
      "entries" => encoded_entries
    }

    jcs_string = Jcs.encode(json_data)
    hash = :crypto.hash(:sha256, jcs_string) |> Base.encode16(case: :lower)

    {hash, jcs_string}
  end

  # lowercase, hyphenated, 36-char RFC 4122 (no braces, no URN prefix).
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @ref_max_bytes 64
  @ref_control_codepoints MapSet.new(Enum.concat([0x00..0x1F, [0x7F, 0x2028, 0x2029]]))

  defp validate_draw_id(draw_id) do
    if Regex.match?(@uuid_regex, draw_id) do
      :ok
    else
      raise ArgumentError,
            "entry_hash: draw_id must be a lowercase, hyphenated UUID, got: #{inspect(draw_id)}"
    end
  end

  defp validate_entry(%{uuid: uuid, weight: weight} = entry) do
    unless is_binary(uuid) and Regex.match?(@uuid_regex, uuid) do
      raise ArgumentError,
            "entry_hash: entry uuid must be a lowercase, hyphenated UUID, got: #{inspect(uuid)}"
    end

    unless is_integer(weight) and weight > 0 do
      raise ArgumentError,
            "entry_hash: weight must be a positive integer, got: #{inspect(weight)}"
    end

    :ok = validate_operator_ref(Map.get(entry, :operator_ref))
    :ok
  end

  defp validate_entry(other) do
    raise ArgumentError,
          "entry_hash: entry must have :uuid and :weight, got: #{inspect(other)}"
  end

  defp validate_operator_ref(ref) when ref in [nil, ""], do: :ok

  defp validate_operator_ref(ref) when is_binary(ref) do
    cond do
      byte_size(ref) > @ref_max_bytes ->
        raise ArgumentError,
              "entry_hash: operator_ref must be ≤ #{@ref_max_bytes} bytes, got #{byte_size(ref)}"

      has_control_char?(ref) ->
        raise ArgumentError,
              "entry_hash: operator_ref must not contain control characters, got: #{inspect(ref)}"

      true ->
        :ok
    end
  end

  defp validate_operator_ref(other) do
    raise ArgumentError,
          "entry_hash: operator_ref must be a string or nil, got: #{inspect(other)}"
  end

  defp has_control_char?(ref) do
    ref
    |> String.to_charlist()
    |> Enum.any?(&MapSet.member?(@ref_control_codepoints, &1))
  end

  defp encode_entry(%{uuid: uuid, weight: weight} = entry) do
    case Map.get(entry, :operator_ref) do
      ref when ref in [nil, ""] ->
        %{"uuid" => uuid, "weight" => weight}

      ref ->
        %{"operator_ref" => ref, "uuid" => uuid, "weight" => weight}
    end
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

  @receipt_schema_version "2"

  @doc """
  Build the canonical JCS payload bytes for an operator commitment receipt.

  Pure function — no IO, no time. Caller passes everything in.

  ## Schema version history

  - **v1** — original: `commitment_hash`, `draw_id`, `entry_hash`,
    `locked_at`, `operator_id`, `operator_slug`, `schema_version`,
    `sequence`, `signing_key_id`.
  - **v2** — adds `winner_count`, declared entropy sources
    (`drand_chain`, `drand_round`, `weather_station`, `weather_time`),
    and algorithm version pinning (`wallop_core_version`,
    `fair_pick_version`). Closes the receipt completeness gaps where
    outcome-influencing fields were trigger-frozen but not
    cryptographically committed.

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
        signing_key_id: signing_key_id,
        winner_count: winner_count,
        drand_chain: drand_chain,
        drand_round: drand_round,
        weather_station: weather_station,
        weather_time: weather_time,
        wallop_core_version: wallop_core_version,
        fair_pick_version: fair_pick_version
      }) do
    payload = %{
      "commitment_hash" => commitment_hash,
      "draw_id" => draw_id,
      "drand_chain" => drand_chain,
      "drand_round" => drand_round,
      "entry_hash" => entry_hash,
      "fair_pick_version" => fair_pick_version,
      "locked_at" => DateTime.to_iso8601(locked_at),
      "operator_id" => operator_id,
      "operator_slug" => to_string(operator_slug),
      "schema_version" => @receipt_schema_version,
      "sequence" => sequence,
      "signing_key_id" => signing_key_id,
      "wallop_core_version" => wallop_core_version,
      "weather_station" => weather_station,
      "weather_time" => maybe_iso8601(weather_time),
      "winner_count" => winner_count
    }

    Jcs.encode(payload)
  end

  defp maybe_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_iso8601(nil), do: nil

  @execution_receipt_schema_version "1"

  @doc """
  Build the canonical JCS payload bytes for an execution receipt.

  Signed by the wallop infrastructure key (not the operator's key).
  Links to the lock receipt via `lock_receipt_hash`.

  `results` must be a flat list of entry_id strings in position order —
  derived from FairPick output via `Enum.map(results, & &1.entry_id)`.
  """
  @spec build_execution_receipt_payload(map()) :: binary()
  def build_execution_receipt_payload(%{
        draw_id: draw_id,
        operator_id: operator_id,
        operator_slug: operator_slug,
        sequence: sequence,
        lock_receipt_hash: lock_receipt_hash,
        entry_hash: entry_hash,
        drand_chain: drand_chain,
        drand_round: drand_round,
        drand_randomness: drand_randomness,
        drand_signature: drand_signature,
        weather_station: weather_station,
        weather_observation_time: weather_observation_time,
        weather_value: weather_value,
        weather_fallback_reason: weather_fallback_reason,
        wallop_core_version: wallop_core_version,
        fair_pick_version: fair_pick_version,
        seed: seed,
        results: results,
        executed_at: %DateTime{} = executed_at
      }) do
    Jcs.encode(%{
      "draw_id" => draw_id,
      "drand_chain" => drand_chain,
      "drand_randomness" => drand_randomness,
      "drand_round" => drand_round,
      "drand_signature" => drand_signature,
      "entry_hash" => entry_hash,
      "executed_at" => DateTime.to_iso8601(executed_at),
      "execution_schema_version" => @execution_receipt_schema_version,
      "fair_pick_version" => fair_pick_version,
      "lock_receipt_hash" => lock_receipt_hash,
      "operator_id" => operator_id,
      "operator_slug" => to_string(operator_slug),
      "results" => results,
      "seed" => seed,
      "sequence" => sequence,
      "wallop_core_version" => wallop_core_version,
      "weather_fallback_reason" => weather_fallback_reason,
      "weather_observation_time" => maybe_iso8601(weather_observation_time),
      "weather_station" => weather_station,
      "weather_value" => weather_value
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
