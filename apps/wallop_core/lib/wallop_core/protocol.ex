defmodule WallopCore.Protocol do
  @moduledoc """
  Wallop commit-reveal protocol operations.

  Entry hashing (§2.1) and seed computation (§2.3) as defined in
  `spec/protocol.md`.

  Timestamps in signed payloads go through `WallopCore.Time.to_rfc3339_usec/1`; the
  canonical-form assertion raises on any timestamp not in that form rather than signing it.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.{Freq, LandObs}

  @doc """
  Compute the entry hash for a draw.

  Canonical form:

      SHA-256(JCS(%{
        "draw_id" => "<lowercase-hyphenated-uuidv4>",
        "entries" => [
          %{"uuid" => "...", "weight" => N},
          ...
        ]
      }))

  Entries are sorted ascending by `uuid` (binary lex). `weight` must be a
  positive integer. All UUIDs must be lowercase, hyphenated RFC 4122 form
  (36 chars, no braces, no URN prefix).

  ## Durable invariant

  **Anything this function hashes must be derivable from the public
  ProofBundle bytes alone.** Do not add fields here that aren't also
  present byte-identically in the public bundle — a third-party verifier
  reading the public bundle must be able to reproduce this exact hash
  without any authenticated operator-only data.

  Input entries may carry extra keys — they are ignored. Only `uuid`
  and `weight` influence the hash.

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
      |> Enum.map(fn %{uuid: uuid, weight: weight} ->
        %{"uuid" => uuid, "weight" => weight}
      end)

    json_data = %{
      "draw_id" => draw_id,
      "entries" => encoded_entries
    }

    jcs_string = Jcs.encode(json_data)
    hash = :crypto.hash(:sha256, jcs_string) |> Base.encode16(case: :lower)

    {hash, jcs_string}
  end

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  defp validate_draw_id(draw_id) do
    if Regex.match?(@uuid_regex, draw_id) do
      :ok
    else
      raise ArgumentError,
            "entry_hash: draw_id must be a lowercase, hyphenated UUID, got: #{inspect(draw_id)}"
    end
  end

  defp validate_entry(%{uuid: uuid, weight: weight}) do
    unless is_binary(uuid) and Regex.match?(@uuid_regex, uuid) do
      raise ArgumentError,
            "entry_hash: entry uuid must be a lowercase, hyphenated UUID, got: #{inspect(uuid)}"
    end

    unless is_integer(weight) and weight > 0 do
      raise ArgumentError,
            "entry_hash: weight must be a positive integer, got: #{inspect(weight)}"
    end

    :ok
  end

  defp validate_entry(other) do
    raise ArgumentError,
          "entry_hash: entry must have :uuid and :weight, got: #{inspect(other)}"
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

  @doc """
  The seed for a grid-frequency draw: SHA-256 over
  JCS{drand_randomness, entry_hash, freq_value}. The `freq_value` key keeps
  it apart from the weather seed and the drand-only seed, even for the same
  string. A grid-frequency fallback uses the drand-only seed,
  `compute_seed/2`.
  """
  @spec compute_freq_seed(String.t(), String.t(), String.t()) :: {<<_::256>>, String.t()}
  def compute_freq_seed(entry_hash, drand_randomness, freq_value) do
    jcs_string =
      Jcs.encode(%{
        "drand_randomness" => drand_randomness,
        "entry_hash" => entry_hash,
        "freq_value" => freq_value
      })

    {:crypto.hash(:sha256, jcs_string), jcs_string}
  end

  @jcs_version "sha256-jcs-v1"
  @signature_algorithm "ed25519"
  @drand_signature_algorithm "bls12_381_g2"
  @merkle_algorithm "sha256-pairwise-v1"

  @spec jcs_version() :: String.t()
  def jcs_version, do: @jcs_version

  @spec signature_algorithm() :: String.t()
  def signature_algorithm, do: @signature_algorithm

  @spec drand_signature_algorithm() :: String.t()
  def drand_signature_algorithm, do: @drand_signature_algorithm

  @spec merkle_algorithm() :: String.t()
  def merkle_algorithm, do: @merkle_algorithm

  defp lock_fields(
         %{
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
         },
         schema_version,
         entropy_composition
       ) do
    payload = %{
      "commitment_hash" => commitment_hash,
      "draw_id" => draw_id,
      "drand_chain" => drand_chain,
      "drand_round" => drand_round,
      "entropy_composition" => entropy_composition,
      "entry_hash" => entry_hash,
      "fair_pick_version" => fair_pick_version,
      "jcs_version" => @jcs_version,
      "locked_at" => WallopCore.Time.to_rfc3339_usec(locked_at),
      "operator_id" => operator_id,
      "operator_slug" => to_string(operator_slug),
      "schema_version" => schema_version,
      "sequence" => sequence,
      "signature_algorithm" => @signature_algorithm,
      "signing_key_id" => signing_key_id,
      "wallop_core_version" => wallop_core_version,
      "weather_station" => weather_station,
      "weather_time" => WallopCore.Time.maybe_to_rfc3339_usec(weather_time),
      "winner_count" => winner_count
    }

    assert_canonical_timestamps!(payload, ["locked_at", "weather_time"])
    payload
  end

  defp execution_fields(
         %{
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
           executed_at: %DateTime{} = executed_at,
           signing_key_id: signing_key_id
         },
         schema_version,
         entropy_composition
       ) do
    payload = %{
      "draw_id" => draw_id,
      "drand_chain" => drand_chain,
      "drand_randomness" => drand_randomness,
      "drand_round" => drand_round,
      "drand_signature" => drand_signature,
      "drand_signature_algorithm" => @drand_signature_algorithm,
      "entropy_composition" => entropy_composition,
      "entry_hash" => entry_hash,
      "executed_at" => WallopCore.Time.to_rfc3339_usec(executed_at),
      "fair_pick_version" => fair_pick_version,
      "jcs_version" => @jcs_version,
      "lock_receipt_hash" => lock_receipt_hash,
      "merkle_algorithm" => @merkle_algorithm,
      "operator_id" => operator_id,
      "operator_slug" => to_string(operator_slug),
      "results" => results,
      "schema_version" => schema_version,
      "seed" => seed,
      "sequence" => sequence,
      "signature_algorithm" => @signature_algorithm,
      "signing_key_id" => signing_key_id,
      "wallop_core_version" => wallop_core_version,
      "weather_fallback_reason" => weather_fallback_reason,
      "weather_observation_time" =>
        WallopCore.Time.maybe_to_rfc3339_usec(weather_observation_time),
      "weather_station" => weather_station,
      "weather_value" => weather_value
    }

    assert_canonical_timestamps!(payload, ["executed_at", "weather_observation_time"])
    payload
  end

  @v6_lock_schema_version "6"
  @v6_execution_schema_version "5"
  @v6_tag_modules [LandObs, Freq]

  @v6_lock_non_nil [
    :operator_id,
    :operator_slug,
    :sequence,
    :draw_id,
    :commitment_hash,
    :entry_hash,
    :locked_at,
    :signing_key_id,
    :winner_count,
    :drand_chain,
    :drand_round,
    :wallop_core_version,
    :fair_pick_version
  ]
  @v6_lock_nullable [:weather_station, :weather_time]
  @v6_exec_non_nil [
    :draw_id,
    :operator_id,
    :operator_slug,
    :sequence,
    :lock_receipt_hash,
    :entry_hash,
    :drand_chain,
    :drand_round,
    :drand_randomness,
    :drand_signature,
    :wallop_core_version,
    :fair_pick_version,
    :seed,
    :results,
    :executed_at,
    :signing_key_id
  ]
  @v6_exec_nullable [
    :weather_station,
    :weather_observation_time,
    :weather_value,
    :weather_fallback_reason
  ]

  @doc "The Met Office Land Observations entropy tag, for lock v6 / execution v5."
  @spec landobs_entropy_composition() :: String.t()
  def landobs_entropy_composition, do: LandObs.tag()

  @doc "The only `weather_fallback_reason` allowed under the Land Observations tag."
  @spec landobs_fallback_reason() :: String.t()
  def landobs_fallback_reason, do: LandObs.fallback_reason()

  @doc "The GB grid frequency entropy tag, for lock v6 / execution v5."
  @spec freq_entropy_composition() :: String.t()
  def freq_entropy_composition, do: Freq.tag()

  @doc "The only `freq_fallback_reason` allowed under the grid-frequency tag."
  @spec freq_fallback_reason() :: String.t()
  def freq_fallback_reason, do: Freq.fallback_reason()

  @doc "The entropy tags accepted by lock v6 / execution v5."
  @spec v6_entropy_compositions() :: [String.t()]
  def v6_entropy_compositions, do: Enum.map(@v6_tag_modules, & &1.tag())

  @doc """
  Build the canonical JCS payload bytes for a lock receipt, schema 6, the
  operator's signed commitment at lock.

  Pure function — no IO, no time. Caller passes everything in.
  `locked_at` must be a `DateTime` with microsecond precision; the caller is
  responsible for capturing it once at lock time and not re-stamping.

  Takes `operator_id`, `operator_slug`, `sequence`, `draw_id`,
  `commitment_hash`, `entry_hash`, `locked_at`, `signing_key_id`,
  `winner_count`, `drand_chain`, `drand_round`, `weather_station`,
  `weather_time`, `wallop_core_version`, `fair_pick_version` and
  `entropy_composition`, which picks the tag's rules and is signed
  verbatim. A tag not in `v6_entropy_compositions/0`, or none, raises
  `ArgumentError`. See the tag modules (`WallopCore.Protocol.Tags.LandObs`,
  `WallopCore.Protocol.Tags.Freq`)
  for each tag's rules.
  """
  @spec build_v6_lock_payload(map()) :: binary()
  def build_v6_lock_payload(input) do
    {tag, module} = v6_tag!(input)
    require_inputs!(input, "lock v6", @v6_lock_non_nil, @v6_lock_nullable, [:locked_at])
    require_quicknet_chain!(input)
    module.validate_lock!(input)

    input
    |> lock_fields(@v6_lock_schema_version, tag)
    |> merge_tag_fields!(module.lock_fields(input))
    |> assert_tag_timestamps!()
    |> Jcs.encode()
  end

  @doc """
  Build the canonical JCS payload bytes for an execution receipt, schema 5.

  Signed by the wallop infrastructure key (not the operator's key). Links
  to the lock receipt via `lock_receipt_hash`. `results` must be a flat list
  of entry_id strings in position order.

  Takes `draw_id`, `operator_id`, `operator_slug`, `sequence`,
  `lock_receipt_hash`, `entry_hash`, `drand_chain`, `drand_round`,
  `drand_randomness`, `drand_signature`, the weather fields
  (`weather_station`, `weather_observation_time`, `weather_value`,
  `weather_fallback_reason`), `wallop_core_version`, `fair_pick_version`,
  `seed`, `results`, `executed_at`, `signing_key_id` and
  `entropy_composition`, chosen and checked as in `build_v6_lock_payload/1`.

  Lock schemas 1 to 5 and execution schemas 1 to 4 are retired: wallop no
  longer builds them, and current tools don't verify them.
  """
  @spec build_v6_execution_payload(map()) :: binary()
  def build_v6_execution_payload(input) do
    {tag, module} = v6_tag!(input)
    require_inputs!(input, "exec v5", @v6_exec_non_nil, @v6_exec_nullable, [:executed_at])
    require_quicknet_chain!(input)
    module.validate_exec!(input)

    input
    |> execution_fields(@v6_execution_schema_version, tag)
    |> merge_tag_fields!(module.exec_fields(input))
    |> assert_tag_timestamps!()
    |> Jcs.encode()
  end

  defp v6_tag!(%{entropy_composition: tag}) do
    case Enum.find(@v6_tag_modules, &(&1.tag() == tag)) do
      nil ->
        raise ArgumentError,
              "unknown entropy_composition for lock v6 / execution v5: #{inspect(tag)}; " <>
                "accepted: #{inspect(v6_entropy_compositions())}"

      module ->
        {tag, module}
    end
  end

  defp v6_tag!(_input) do
    raise ArgumentError, "lock v6 / execution v5 input must carry :entropy_composition"
  end

  defp require_inputs!(input, receipt, non_nil, nullable, datetimes) do
    Enum.each(non_nil ++ nullable, fn key ->
      unless Map.has_key?(input, key),
        do: raise(ArgumentError, "#{receipt} input must carry #{inspect(key)}")
    end)

    Enum.each(non_nil, fn key ->
      if is_nil(Map.fetch!(input, key)),
        do: raise(ArgumentError, "#{receipt} #{key} must not be nil")
    end)

    Enum.each(datetimes, fn key ->
      unless match?(%DateTime{}, Map.fetch!(input, key)),
        do: raise(ArgumentError, "#{receipt} #{key} must be a DateTime")
    end)
  end

  defp require_quicknet_chain!(%{drand_chain: chain}) do
    unless chain == Quicknet.chain_hash() do
      raise ArgumentError,
            "lock v6 / execution v5 drand_chain must be the quicknet chain " <>
              "#{Quicknet.chain_hash()}, got: #{inspect(chain)}"
    end

    :ok
  end

  defp require_quicknet_chain!(_input) do
    raise ArgumentError, "lock v6 / execution v5 input must carry :drand_chain"
  end

  @v6_tag_timestamp_keys ["freq_start"]

  defp assert_tag_timestamps!(payload) do
    assert_canonical_timestamps!(
      payload,
      Enum.filter(@v6_tag_timestamp_keys, &Map.has_key?(payload, &1))
    )

    payload
  end

  defp merge_tag_fields!(base, extra) do
    case Enum.reject(Map.keys(extra), &is_binary/1) do
      [] -> :ok
      bad -> raise ArgumentError, "tag field keys must be strings, got: #{inspect(bad)}"
    end

    case Enum.filter(Map.keys(extra), &Map.has_key?(base, &1)) do
      [] -> Map.merge(base, extra)
      clash -> raise ArgumentError, "tag fields would replace base fields: #{inspect(clash)}"
    end
  end

  defp assert_canonical_timestamps!(payload, keys) do
    Enum.each(keys, fn key ->
      case WallopCore.Time.validate_rfc3339_usec(Map.fetch!(payload, key)) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError,
                "signed-payload timestamp field #{inspect(key)} is not canonical: #{reason}"
      end
    end)
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
  Verify a keyring row is internally consistent before signing with it.

  Re-derives the public key from the (already-decrypted) Ed25519 private
  key, asserts it matches the row's `public_key`, and asserts
  `key_id(public_key) == key_id`. Returns `:ok` on success, or
  `{:error, :public_key_mismatch}` / `{:error, :key_id_mismatch}` on the
  respective inconsistency.

  Defence-in-depth on the producer side: catches a corrupted in-memory
  key (e.g. truncated bytes after Vault decrypt), a row whose `key_id`
  column drifted out of sync with `public_key`, or a row whose
  `public_key` was rewritten without rotating `key_id`. Neither failure
  mode should be reachable through the existing Ash policy + DB trigger
  surface, but the check is cheap and runs on every sign.

  Belongs in the signing path immediately after the private-key decrypt
  step, before the bytes are passed to `sign_receipt/2`.
  """
  @spec assert_key_consistency(binary(), binary(), String.t()) ::
          :ok | {:error, :public_key_mismatch | :key_id_mismatch}
  def assert_key_consistency(public_key, private_key, key_id)
      when byte_size(public_key) == 32 and byte_size(private_key) == 32 and
             is_binary(key_id) and byte_size(key_id) > 0 do
    {derived_pub, _priv} = :crypto.generate_key(:eddsa, :ed25519, private_key)

    cond do
      derived_pub != public_key -> {:error, :public_key_mismatch}
      key_id(public_key) != key_id -> {:error, :key_id_mismatch}
      true -> :ok
    end
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
