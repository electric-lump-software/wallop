defmodule WallopCore.TamperVectors do
  @moduledoc """
  Builds `spec/vectors/proof-bundle-v6-tamper.json`: signed lock v6 /
  execution v5 proof bundles, each with exactly one signed field tampered.

  Every bundle starts from a valid base built by the real builders
  (`Protocol.build_v6_lock_payload/1`, `Protocol.build_v6_execution_payload/1`)
  on a real quicknet round. One field of one receipt is then changed and
  the receipt is signed again with the vector key, so the signature always
  verifies and only the semantic checks can refuse the bundle. When the lock
  receipt is changed, the execution receipt's `lock_receipt_hash` is
  recomputed and the execution receipt signed again too, so the linkage
  holds and the tampered field is the only change a verifier can see.

  Each case names the exact set of verifier steps (snake_case `StepName`)
  expected to fail. The keys are carried inline at the top level, as
  `[{key_id, public_key_hex, key_class, inserted_at}]`.

  Regenerate with:

      MIX_ENV=test mix run apps/wallop_core/test/wallop_core/tamper_vectors_generator.exs

  `WallopCore.Invariants.TamperTest` checks the committed file equals
  `encode/0`, and that each case changes exactly one signed field.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Weather.{Schedule, Stations}

  @path Path.expand("../../../../spec/vectors/proof-bundle-v6-tamper.json", __DIR__)

  # A real quicknet beacon, published 2026-10-14T20:00:00Z; the same round
  # the v6 builder tests use. Its observation hour is 19:00.
  @round 33_068_212
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"
  @weather_value "141;1025;85;2432"
  @locked_at ~U[2026-10-14 18:00:00.123456Z]
  @executed_at ~U[2026-10-14 20:00:06.000000Z]
  @key_inserted_at "2026-10-01T00:00:00.000000Z"

  @draw_id "dddddddd-2222-4222-8222-222222222222"
  @operator_id "11111111-1111-4111-8111-111111111111"
  @entries [
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  ]
  @winner_count 2

  @mainnet_chain "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"
  @forecast_tag "drand-quicknet+openmeteo-v1"
  @other_uuid "33333333-3333-4333-8333-333333333333"
  @other_hash String.duplicate("ab", 32)

  @doc "Where the vector file lives."
  def path, do: @path

  @doc "The vector's real quicknet round."
  def round, do: @round

  @doc "The vector's signed `locked_at` and `executed_at`."
  def locked_at, do: @locked_at
  def executed_at, do: @executed_at

  @doc """
  The two deterministic vector keys, `{private, public, key_id}`, from the
  seeds `sha256("wallop-vector-operator-key")` and
  `sha256("wallop-vector-infrastructure-key")`.
  """
  def operator_key, do: key("wallop-vector-operator-key")
  def infrastructure_key, do: key("wallop-vector-infrastructure-key")

  defp key(label) do
    seed = :crypto.hash(:sha256, label)
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {seed, public, Protocol.key_id(public)}
  end

  @doc "The entry hash every vector bundle commits to."
  def entry_hash do
    {hash, _} =
      Protocol.entry_hash({@draw_id, Enum.map(@entries, &%{uuid: &1, weight: 1})})

    hash
  end

  @doc "Builder input for the base lock receipt."
  def lock_input do
    {_, _, kid} = operator_key()

    %{
      entropy_composition: Protocol.landobs_entropy_composition(),
      operator_id: @operator_id,
      operator_slug: "acme-prizes",
      sequence: 7,
      draw_id: @draw_id,
      commitment_hash: entry_hash(),
      entry_hash: entry_hash(),
      locked_at: @locked_at,
      signing_key_id: kid,
      winner_count: @winner_count,
      drand_chain: Quicknet.chain_hash(),
      drand_round: @round,
      weather_station: Stations.primary().id,
      weather_time: Schedule.weather_time_for_round(@round),
      wallop_core_version: "0.29.0",
      fair_pick_version: "0.2.1"
    }
  end

  @doc """
  Builder input for a base execution receipt, `:observed` or `:fallback`,
  linked to `lock_jcs`. The seed and results are computed, so they agree.
  """
  def exec_input(kind, lock_jcs) do
    {_, _, kid} = infrastructure_key()
    lock = lock_input()

    weather =
      case kind do
        :observed ->
          %{
            weather_station: Stations.primary().id,
            weather_value: @weather_value,
            weather_observation_time: lock.weather_time,
            weather_fallback_reason: nil
          }

        :fallback ->
          %{
            weather_station: Stations.primary().id,
            weather_value: nil,
            weather_observation_time: nil,
            weather_fallback_reason: Protocol.landobs_fallback_reason()
          }
      end

    {seed, results} = seed_and_results(weather.weather_value)

    Map.merge(weather, %{
      entropy_composition: lock.entropy_composition,
      draw_id: @draw_id,
      operator_id: @operator_id,
      operator_slug: lock.operator_slug,
      sequence: lock.sequence,
      lock_receipt_hash: sha256_hex(lock_jcs),
      entry_hash: entry_hash(),
      drand_chain: Quicknet.chain_hash(),
      drand_round: @round,
      drand_randomness: @randomness,
      drand_signature: @signature,
      wallop_core_version: lock.wallop_core_version,
      fair_pick_version: lock.fair_pick_version,
      seed: Base.encode16(seed, case: :lower),
      results: Enum.map(results, & &1.entry_id),
      executed_at: @executed_at,
      signing_key_id: kid
    })
  end

  defp seed_and_results(weather_value) do
    {seed, _} =
      if weather_value,
        do: Protocol.compute_seed(entry_hash(), @randomness, weather_value),
        else: Protocol.compute_seed(entry_hash(), @randomness)

    entries = Enum.map(@entries, &%{id: &1, weight: 1})
    {seed, FairPick.draw(entries, seed, @winner_count)}
  end

  @doc "The base `{lock_jcs, exec_jcs}` for `:observed` or `:fallback`, from the real builders."
  def base(kind) do
    lock_jcs = Protocol.build_v6_lock_payload(lock_input())
    {lock_jcs, Protocol.build_v6_execution_payload(exec_input(kind, lock_jcs))}
  end

  @doc """
  Every tamper case: `{name, base, receipt, field, value, mutation,
  expected_failing_steps}`. `value` is the tampered field's new JSON value.
  """
  def cases do
    wt = Schedule.weather_time_for_round(@round)
    pub = Quicknet.pub_time(@round)
    latest = Schedule.latest_lock_at(wt)
    next_hour_round = @round + 1200

    [
      # ── Lock receipt ──────────────────────────────────────────────
      {"lock_drand_round_plus_one", :observed, :lock, "drand_round", @round + 1,
       "+1 round (same observation hour)", ~w(receipt_field_consistency)},
      {"lock_drand_round_minus_one", :observed, :lock, "drand_round", @round - 1,
       "-1 round (same observation hour)", ~w(receipt_field_consistency)},
      {"lock_drand_round_next_hour", :observed, :lock, "drand_round", next_hour_round,
       "+1 hour of rounds (+1200)", ~w(receipt_field_consistency weather_observation_window)},
      {"lock_drand_round_string", :observed, :lock, "drand_round", Integer.to_string(@round),
       "wrong type: a string",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"lock_weather_time_plus_hour", :observed, :lock, "weather_time", rfc(add_h(wt, 1)),
       "+1 hour", ~w(weather_observation_window)},
      {"lock_weather_time_minus_hour", :observed, :lock, "weather_time", rfc(add_h(wt, -1)),
       "-1 hour", ~w(weather_observation_window)},
      {"lock_weather_time_plus_1us", :observed, :lock, "weather_time", rfc(add_us(wt, 1)),
       "+1 µs (not a whole hour)", ~w(bundle_shape weather_observation_window)},
      {"lock_weather_time_null", :observed, :lock, "weather_time", nil, "nil",
       ~w(bundle_shape lock_signature weather_observation_window)},
      {"lock_locked_at_after_limit", :observed, :lock, "locked_at", rfc(add_us(latest, 1)),
       "latest_lock_at + 1 µs", ~w(weather_observation_window)},
      {"lock_locked_at_after_round", :observed, :lock, "locked_at", rfc(add_us(pub, 1)),
       "pub(R) + 1 µs", ~w(weather_observation_window drand_bls_signature)},
      {"lock_locked_at_not_canonical", :observed, :lock, "locked_at",
       "2026-10-14T18:00:00.123456+00:00", "a +00:00 offset",
       ~w(bundle_shape drand_bls_signature temporal_binding weather_observation_window)},
      {"lock_weather_station_backup", :observed, :lock, "weather_station", Stations.backup().id,
       "the other station", ~w(bundle_shape receipt_field_consistency)},
      {"lock_weather_station_null", :observed, :lock, "weather_station", nil, "nil",
       ~w(bundle_shape lock_signature receipt_field_consistency)},
      {"lock_drand_chain_mainnet", :observed, :lock, "drand_chain", @mainnet_chain,
       "a different chain", ~w(receipt_field_consistency)},
      {"lock_entropy_composition_forecast", :observed, :lock, "entropy_composition",
       @forecast_tag, "a different tag",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"lock_schema_version_5", :observed, :lock, "schema_version", "5", "a different schema",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"lock_draw_id_other", :observed, :lock, "draw_id", @other_uuid, "another draw",
       ~w(receipt_field_consistency)},
      {"lock_operator_id_other", :observed, :lock, "operator_id", @other_uuid, "another operator",
       ~w(receipt_field_consistency)},
      {"lock_sequence_plus_one", :observed, :lock, "sequence", 8, "+1",
       ~w(receipt_field_consistency)},
      {"lock_sequence_string", :observed, :lock, "sequence", "7", "wrong type: a string",
       ~w(bundle_shape lock_signature receipt_field_consistency)},
      {"lock_entry_hash_other", :observed, :lock, "entry_hash", @other_hash, "another hash",
       ~w(lock_receipt_entry_hash)},
      {"lock_winner_count_plus_one", :observed, :lock, "winner_count", @winner_count + 1, "+1",
       ~w(winner_selection)},
      {"lock_signing_key_id_other", :observed, :lock, "signing_key_id", "deadbeef",
       "an unknown key", ~w(lock_signature)},
      {"lock_jcs_version_other", :observed, :lock, "jcs_version", "sha256-jcs-v2",
       "a different value", ~w(bundle_shape)},
      {"lock_signature_algorithm_other", :observed, :lock, "signature_algorithm", "ed448",
       "a different value", ~w(bundle_shape)},

      # ── Execution receipt ─────────────────────────────────────────
      {"exec_drand_round_plus_one", :observed, :exec, "drand_round", @round + 1, "+1 round",
       ~w(drand_bls_signature receipt_field_consistency)},
      {"exec_drand_round_minus_one", :observed, :exec, "drand_round", @round - 1, "-1 round",
       ~w(drand_bls_signature receipt_field_consistency)},
      {"exec_drand_randomness_other", :observed, :exec, "drand_randomness", @other_hash,
       "other randomness", ~w(drand_bls_signature seed_recomputation)},
      {"exec_drand_signature_other", :observed, :exec, "drand_signature",
       String.duplicate("ab", 48), "another signature", ~w(drand_bls_signature)},
      {"exec_drand_chain_mainnet", :observed, :exec, "drand_chain", @mainnet_chain,
       "a different chain", ~w(drand_bls_signature receipt_field_consistency)},
      {"exec_drand_signature_algorithm_other", :observed, :exec, "drand_signature_algorithm",
       "bls12_381_g1", "a different value", ~w(bundle_shape)},
      {"exec_draw_id_other", :observed, :exec, "draw_id", @other_uuid, "another draw",
       ~w(receipt_field_consistency)},
      {"exec_operator_id_other", :observed, :exec, "operator_id", @other_uuid, "another operator",
       ~w(receipt_field_consistency)},
      {"exec_sequence_plus_one", :observed, :exec, "sequence", 8, "+1",
       ~w(receipt_field_consistency)},
      {"exec_entropy_composition_forecast", :observed, :exec, "entropy_composition",
       @forecast_tag, "a different tag",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"exec_schema_version_4", :observed, :exec, "schema_version", "4", "a different schema",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"exec_entry_hash_other", :observed, :exec, "entry_hash", @other_hash, "another hash",
       ~w(exec_receipt_entry_hash)},
      {"exec_executed_at_before_round", :observed, :exec, "executed_at", rfc(add_us(pub, -1)),
       "pub(R) - 1 µs", ~w(drand_bls_signature)},
      {"exec_executed_at_not_canonical", :observed, :exec, "executed_at", "2026-10-14T20:00:06Z",
       "no fraction", ~w(bundle_shape drand_bls_signature temporal_binding)},
      {"exec_lock_receipt_hash_other", :observed, :exec, "lock_receipt_hash", @other_hash,
       "another hash", ~w(receipt_linkage)},
      {"exec_merkle_algorithm_other", :observed, :exec, "merkle_algorithm", "sha256-pairwise-v2",
       "a different value", ~w(bundle_shape)},
      {"exec_seed_other", :observed, :exec, "seed", @other_hash, "another seed",
       ~w(seed_recomputation)},
      {"exec_results_reversed", :observed, :exec, "results", :reverse, "winners reversed",
       ~w(winner_selection)},
      {"exec_signing_key_id_other", :observed, :exec, "signing_key_id", "deadbeef",
       "an unknown key", ~w(exec_signature)},
      {"exec_weather_station_not_listed", :observed, :exec, "weather_station", "wmo-03772",
       "a station not in the tag", ~w(bundle_shape receipt_field_consistency)},
      {"exec_weather_station_null", :observed, :exec, "weather_station", nil, "nil",
       ~w(bundle_shape receipt_field_consistency)},
      {"exec_weather_value_other", :observed, :exec, "weather_value", "142;1025;85;2432",
       "+1 tenth °C", ~w(drand_bls_signature seed_recomputation)},
      {"exec_weather_value_grammar", :observed, :exec, "weather_value", "-0;1025;85;2432",
       "off grammar", ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"exec_weather_observation_time_plus_hour", :observed, :exec, "weather_observation_time",
       rfc(add_h(wt, 1)), "+1 hour", ~w(weather_observation_window)},
      {"exec_weather_observation_time_null", :observed, :exec, "weather_observation_time", nil,
       "nil with a value", ~w(weather_observation_window)},
      {"exec_weather_fallback_reason_on_observed", :observed, :exec, "weather_fallback_reason",
       Protocol.landobs_fallback_reason(), "a reason with a value",
       ~w(weather_observation_window)},
      {"exec_fallback_station_backup", :fallback, :exec, "weather_station", Stations.backup().id,
       "the other station on a fallback", ~w(receipt_field_consistency)},
      {"exec_fallback_reason_v5", :fallback, :exec, "weather_fallback_reason", "unreachable",
       "a schema 4 reason", ~w(bundle_shape weather_observation_window)},
      {"exec_fallback_reason_null", :fallback, :exec, "weather_fallback_reason", nil,
       "nil on a fallback", ~w(weather_observation_window)},
      {"exec_jcs_version_other", :observed, :exec, "jcs_version", "sha256-jcs-v2",
       "a different value", ~w(bundle_shape)},
      {"exec_signature_algorithm_other", :observed, :exec, "signature_algorithm", "ed448",
       "a different value", ~w(bundle_shape)}
    ]
  end

  @doc "The vector as a map."
  def build do
    %{
      "description" =>
        "Signed lock v6 / execution v5 proof bundles, each with exactly one signed " <>
          "field tampered and re-signed with the vector key, so only the semantic " <>
          "checks can refuse it. When the lock receipt is tampered, the execution " <>
          "receipt's lock_receipt_hash is recomputed and re-signed too. Each case " <>
          "must fail exactly expected_failing_steps and never pass. The bases pass.",
      "keys" => keys(),
      "bases" =>
        for kind <- [:observed, :fallback] do
          {lock_jcs, exec_jcs} = base(kind)

          %{
            "name" => Atom.to_string(kind),
            "bundle" => bundle(lock_jcs, exec_jcs, kind),
            "expected_passed" => true
          }
        end,
      "cases" =>
        for {name, kind, receipt, field, value, mutation, steps} <- cases() do
          %{
            "name" => name,
            "base" => Atom.to_string(kind),
            "receipt" => Atom.to_string(receipt),
            "field" => field,
            "mutation" => mutation,
            "bundle" => tampered_bundle(kind, receipt, field, value),
            "expected_failing_steps" => Enum.sort(steps)
          }
        end
    }
  end

  @doc "The vector file's bytes: pretty JSON with sorted keys and a trailing newline."
  def encode do
    build() |> sorted() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")
  end

  defp sorted(map) when is_map(map),
    do:
      map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Jason.OrderedObject.new()

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other

  defp keys do
    {_, op_pub, op_kid} = operator_key()
    {_, infra_pub, infra_kid} = infrastructure_key()

    [
      key_entry(op_kid, op_pub, "operator"),
      key_entry(infra_kid, infra_pub, "infrastructure")
    ]
  end

  defp key_entry(kid, public, class) do
    %{
      "key_id" => kid,
      "public_key_hex" => Base.encode16(public, case: :lower),
      "key_class" => class,
      "inserted_at" => @key_inserted_at
    }
  end

  @doc "The base bundle of `kind` with one field of one receipt replaced, re-signed."
  def tampered_bundle(kind, receipt, field, value) do
    {lock_jcs, exec_jcs} = base(kind)

    case receipt do
      :lock ->
        lock_jcs = put_field(lock_jcs, field, value)

        exec_jcs =
          put_field(exec_jcs, "lock_receipt_hash", sha256_hex(lock_jcs))

        bundle(lock_jcs, exec_jcs, kind)

      :exec ->
        bundle(lock_jcs, put_field(exec_jcs, field, value), kind)
    end
  end

  @doc "Decodes `jcs`, sets `field` to `value` and encodes it again as JCS."
  def put_field(jcs, field, :reverse) do
    payload = Jason.decode!(jcs)
    Jcs.encode(%{payload | field => Enum.reverse(Map.fetch!(payload, field))})
  end

  def put_field(jcs, field, value) do
    payload = Jason.decode!(jcs)
    true = Map.has_key?(payload, field)
    Jcs.encode(%{payload | field => value})
  end

  @doc "The proof bundle envelope (JCS bytes) around two signed receipts."
  def bundle(lock_jcs, exec_jcs, kind) do
    {op_sk, _, _} = operator_key()
    {infra_sk, _, _} = infrastructure_key()
    weather_value = if kind == :observed, do: @weather_value
    {_, results} = seed_and_results(weather_value)

    entropy =
      %{
        "drand_round" => @round,
        "drand_randomness" => @randomness,
        "drand_signature" => @signature,
        "drand_chain_hash" => Quicknet.chain_hash()
      }
      |> then(&if weather_value, do: Map.put(&1, "weather_value", weather_value), else: &1)

    Jcs.encode(%{
      "version" => 1,
      "draw_id" => @draw_id,
      "entries" => Enum.map(@entries, &%{"uuid" => &1, "weight" => 1}),
      "results" => Enum.map(results, &%{"entry_id" => &1.entry_id, "position" => &1.position}),
      "entropy" => entropy,
      "lock_receipt" => signed(lock_jcs, op_sk),
      "execution_receipt" => signed(exec_jcs, infra_sk)
    })
  end

  defp signed(jcs, sk) do
    %{
      "payload_jcs" => jcs,
      "signature_hex" => Base.encode16(Protocol.sign_receipt(jcs, sk), case: :lower)
    }
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp rfc(dt), do: WallopCore.Time.to_rfc3339_usec(dt)
  defp add_h(dt, n), do: DateTime.add(dt, n * 3600)
  defp add_us(dt, n), do: DateTime.add(dt, n, :microsecond)
end
