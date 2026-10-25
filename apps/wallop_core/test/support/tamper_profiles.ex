defmodule WallopCore.TamperProfiles do
  @moduledoc """
  What the tamper vectors need to know about one entropy tag: its vector
  file, its input fields, seed, unsigned entropy key, base names, key sets
  and cases. Everything else (the round, the beacon, the draw, the keys,
  the envelope) is shared, in `WallopCore.TamperVectors`.

  Each profile writes its own vector file, so adding a tag never changes
  the bytes of another tag's file.
  """

  @type kind :: :observed | :freq_fallback | :fallback
  @type case_tuple ::
          {String.t(), kind(), :lock | :exec | :both, String.t(), term(), String.t(),
           [String.t()]}

  @callback tag() :: String.t()
  @callback vector_file() :: String.t()
  @callback kinds() :: [kind()]
  @callback description() :: String.t()
  @callback lock_keys() :: [String.t()]
  @callback exec_keys() :: [String.t()]
  @callback base_name(kind()) :: String.t()
  @callback locked_at() :: DateTime.t()
  @callback lock_fields() :: map()
  @callback exec_fields(kind()) :: map()
  @callback seed(String.t(), String.t(), kind()) :: {binary(), String.t()}
  @callback entropy(kind()) :: map()
  @callback cases() :: [case_tuple()]
end

defmodule WallopCore.TamperProfiles.LandObs do
  @moduledoc """
  The Land Observations tag's tamper profile. Its bases are the three
  execution states: `:observed` (a reading), `:freq_fallback` (no reading,
  the round's grid-frequency window) and `:fallback` (neither, drand alone).
  """
  @behaviour WallopCore.TamperProfiles

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.TamperVectors, as: V
  alias WallopCore.Weather.{Schedule, Stations}

  @weather_value "141;1025;85;2432"
  @freq_value "50012;50018;50012;49983;49980;49953;49912;49883"
  @locked_at ~U[2026-10-14 18:00:00.123456Z]

  @impl true
  def tag, do: LandObs.tag()
  @impl true
  def vector_file, do: "proof-bundle-v6-tamper.json"
  @impl true
  def kinds, do: [:observed, :freq_fallback, :fallback]

  @impl true
  def description,
    do:
      "Signed lock v6 / execution v5 proof bundles, each with exactly one signed " <>
        "field tampered (on one receipt, or on both for receipt both) and " <>
        "re-signed with the vector key, so only the semantic " <>
        "checks can refuse it. When the lock receipt is tampered, the execution " <>
        "receipt's lock_receipt_hash is recomputed and re-signed too. Each case " <>
        "must fail exactly expected_failing_steps and never pass. The bases pass."

  @impl true
  def lock_keys, do: LandObs.lock_keys()
  @impl true
  def exec_keys, do: LandObs.exec_keys()
  @impl true
  # Published name; internally the kind stays :freq_fallback (state b).
  def base_name(:freq_fallback), do: "freq_window"
  def base_name(kind), do: Atom.to_string(kind)
  @impl true
  def locked_at, do: @locked_at

  @impl true
  def lock_fields do
    %{
      entropy_composition: LandObs.tag(),
      locked_at: @locked_at,
      weather_station: Stations.primary().id,
      weather_time: Schedule.weather_time_for_round(V.round()),
      freq_start: WallopCore.Frequency.Schedule.freq_start_for_round(V.round())
    }
  end

  @impl true
  def exec_fields(:observed) do
    %{
      weather_station: Stations.primary().id,
      weather_value: @weather_value,
      weather_observation_time: Schedule.weather_time_for_round(V.round()),
      weather_fallback_reason: nil,
      freq_value: nil,
      freq_fallback_reason: nil
    }
  end

  # State (b): no reading by F; the round's grid-frequency window.
  def exec_fields(:freq_fallback) do
    %{
      weather_station: Stations.primary().id,
      weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: Protocol.landobs_fallback_reason(),
      freq_value: @freq_value,
      freq_fallback_reason: nil
    }
  end

  # State (c): no reading and no window, so drand alone.
  def exec_fields(:fallback) do
    %{
      weather_station: Stations.primary().id,
      weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: Protocol.landobs_fallback_reason(),
      freq_value: nil,
      freq_fallback_reason: Protocol.freq_fallback_reason()
    }
  end

  @impl true
  def seed(entry_hash, randomness, :observed),
    do: Protocol.compute_seed(entry_hash, randomness, @weather_value)

  def seed(entry_hash, randomness, :freq_fallback),
    do: Protocol.compute_freq_seed(entry_hash, randomness, @freq_value)

  def seed(entry_hash, randomness, :fallback), do: Protocol.compute_seed(entry_hash, randomness)

  @impl true
  def entropy(:observed), do: %{"weather_value" => @weather_value}
  def entropy(:freq_fallback), do: %{"freq_value" => @freq_value}
  def entropy(:fallback), do: %{}

  @impl true
  def cases do
    wt = Schedule.weather_time_for_round(V.round())
    t = WallopCore.Frequency.Schedule.freq_start_for_round(V.round())
    pub = Quicknet.pub_time(V.round())
    latest = Schedule.latest_lock_at(wt)
    next_hour_round = V.round() + 1200

    [
      # ── Lock receipt ──────────────────────────────────────────────
      {"lock_drand_round_plus_one", :observed, :lock, "drand_round", V.round() + 1,
       "+1 round (same observation hour)", ~w(receipt_field_consistency)},
      {"lock_drand_round_minus_one", :observed, :lock, "drand_round", V.round() - 1,
       "-1 round (same observation hour, the previous window)",
       ~w(receipt_field_consistency weather_observation_window)},
      {"lock_drand_round_next_hour", :observed, :lock, "drand_round", next_hour_round,
       "+1 hour of rounds (+1200)", ~w(receipt_field_consistency weather_observation_window)},
      {"lock_drand_round_string", :observed, :lock, "drand_round", Integer.to_string(V.round()),
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
      {"lock_locked_at_offset_bst", :observed, :lock, "locked_at",
       "2026-10-14T19:00:00.123456+01:00", "the same instant at +01:00",
       ~w(bundle_shape drand_bls_signature temporal_binding weather_observation_window)},
      {"lock_weather_time_offset_utc", :observed, :lock, "weather_time", offset(wt, 0),
       "a +00:00 offset", ~w(bundle_shape weather_observation_window)},
      {"lock_weather_time_offset_bst", :observed, :lock, "weather_time", offset(wt, 1),
       "the same instant at +01:00", ~w(bundle_shape weather_observation_window)},
      {"lock_weather_station_wittering", :observed, :lock, "weather_station", "wmo-03462",
       "Wittering", ~w(bundle_shape receipt_field_consistency)},
      {"lock_weather_station_null", :observed, :lock, "weather_station", nil, "nil",
       ~w(bundle_shape lock_signature receipt_field_consistency)},
      {"lock_freq_start_plus_15s", :observed, :lock, "freq_start", rfc(DateTime.add(t, 15)),
       "+15 s (the next window)", ~w(weather_observation_window)},
      {"lock_freq_start_minus_15s", :observed, :lock, "freq_start", rfc(DateTime.add(t, -15)),
       "-15 s (the previous window)", ~w(weather_observation_window)},
      {"lock_freq_start_plus_1s", :observed, :lock, "freq_start", rfc(DateTime.add(t, 1)),
       "+1 s (not a window start)", ~w(bundle_shape weather_observation_window)},
      {"lock_freq_start_null", :observed, :lock, "freq_start", nil, "nil",
       ~w(bundle_shape lock_signature weather_observation_window)},
      {"lock_freq_start_offset_bst", :observed, :lock, "freq_start", offset(t, 1),
       "the same instant at +01:00", ~w(bundle_shape weather_observation_window)},
      {"lock_drand_chain_mainnet", :observed, :lock, "drand_chain", V.mainnet_chain(),
       "a different chain", ~w(receipt_field_consistency)},
      {"lock_entropy_composition_forecast", :observed, :lock, "entropy_composition",
       V.forecast_tag(), "a different tag",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"lock_schema_version_5", :observed, :lock, "schema_version", "5", "a different schema",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"lock_draw_id_other", :observed, :lock, "draw_id", V.other_uuid(), "another draw",
       ~w(receipt_field_consistency)},
      {"lock_operator_id_other", :observed, :lock, "operator_id", V.other_uuid(),
       "another operator", ~w(receipt_field_consistency)},
      {"lock_sequence_plus_one", :observed, :lock, "sequence", 8, "+1",
       ~w(receipt_field_consistency)},
      {"lock_sequence_string", :observed, :lock, "sequence", "7", "wrong type: a string",
       ~w(bundle_shape lock_signature receipt_field_consistency)},
      {"lock_entry_hash_other", :observed, :lock, "entry_hash", V.other_hash(), "another hash",
       ~w(lock_receipt_entry_hash)},
      {"lock_winner_count_plus_one", :observed, :lock, "winner_count", V.winner_count() + 1, "+1",
       ~w(winner_selection)},
      {"lock_signing_key_id_other", :observed, :lock, "signing_key_id", "deadbeef",
       "an unknown key", ~w(lock_signature)},
      {"lock_jcs_version_other", :observed, :lock, "jcs_version", "sha256-jcs-v2",
       "a different value", ~w(bundle_shape)},
      {"lock_signature_algorithm_other", :observed, :lock, "signature_algorithm", "ed448",
       "a different value", ~w(bundle_shape)},
      {"lock_sequence_float", :observed, :lock, "sequence", {:float, 7},
       "wrong type: 7.0 in the signed bytes",
       ~w(bundle_shape lock_signature receipt_field_consistency)},
      {"lock_drand_round_float", :observed, :lock, "drand_round", {:float, V.round()},
       "wrong type: a float in the signed bytes",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"lock_winner_count_float", :observed, :lock, "winner_count", {:float, V.winner_count()},
       "wrong type: a float in the signed bytes",
       ~w(bundle_shape lock_signature winner_selection)},
      {"lock_fair_pick_version_other", :observed, :lock, "fair_pick_version", "0.1.0",
       "another released version than the exec's", ~w(receipt_field_consistency)},
      {"lock_operator_slug_other", :observed, :lock, "operator_slug", "someone-else",
       "another slug than the exec's", ~w(receipt_field_consistency)},
      {"lock_commitment_hash_other", :observed, :lock, "commitment_hash", V.other_hash(),
       "not the entry_hash", ~w(lock_receipt_entry_hash)},
      {"lock_commitment_hash_upper_case", :observed, :lock, "commitment_hash",
       String.upcase(V.entry_hash()), "the entry_hash in upper case",
       ~w(lock_receipt_entry_hash)},

      # ── Execution receipt ─────────────────────────────────────────
      {"exec_drand_round_plus_one", :observed, :exec, "drand_round", V.round() + 1, "+1 round",
       ~w(drand_bls_signature receipt_field_consistency)},
      {"exec_drand_round_minus_one", :observed, :exec, "drand_round", V.round() - 1, "-1 round",
       ~w(drand_bls_signature receipt_field_consistency)},
      {"exec_drand_randomness_other", :observed, :exec, "drand_randomness", V.other_hash(),
       "other randomness", ~w(drand_bls_signature seed_recomputation)},
      {"exec_drand_signature_other", :observed, :exec, "drand_signature",
       String.duplicate("ab", 48), "another signature", ~w(drand_bls_signature)},
      {"exec_drand_chain_mainnet", :observed, :exec, "drand_chain", V.mainnet_chain(),
       "a different chain", ~w(drand_bls_signature receipt_field_consistency)},
      {"exec_drand_signature_algorithm_other", :observed, :exec, "drand_signature_algorithm",
       "bls12_381_g1", "a different value", ~w(bundle_shape)},
      {"exec_draw_id_other", :observed, :exec, "draw_id", V.other_uuid(), "another draw",
       ~w(receipt_field_consistency)},
      {"exec_operator_id_other", :observed, :exec, "operator_id", V.other_uuid(),
       "another operator", ~w(receipt_field_consistency)},
      {"exec_sequence_plus_one", :observed, :exec, "sequence", 8, "+1",
       ~w(receipt_field_consistency)},
      {"exec_entropy_composition_forecast", :observed, :exec, "entropy_composition",
       V.forecast_tag(), "a different tag",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"exec_schema_version_4", :observed, :exec, "schema_version", "4", "a different schema",
       ~w(bundle_shape exec_signature receipt_field_consistency weather_observation_window)},
      {"exec_entry_hash_other", :observed, :exec, "entry_hash", V.other_hash(), "another hash",
       ~w(exec_receipt_entry_hash)},
      {"exec_executed_at_before_round", :observed, :exec, "executed_at", rfc(add_us(pub, -1)),
       "pub(R) - 1 µs", ~w(drand_bls_signature)},
      {"exec_executed_at_not_canonical", :observed, :exec, "executed_at", "2026-10-14T20:00:06Z",
       "no fraction", ~w(bundle_shape drand_bls_signature temporal_binding)},
      {"exec_executed_at_offset_utc", :observed, :exec, "executed_at", offset(V.executed_at(), 0),
       "a +00:00 offset", ~w(bundle_shape drand_bls_signature temporal_binding)},
      {"exec_executed_at_offset_bst", :observed, :exec, "executed_at", offset(V.executed_at(), 1),
       "the same instant at +01:00", ~w(bundle_shape drand_bls_signature temporal_binding)},
      {"exec_lock_receipt_hash_other", :observed, :exec, "lock_receipt_hash", V.other_hash(),
       "another hash", ~w(receipt_linkage)},
      {"exec_merkle_algorithm_other", :observed, :exec, "merkle_algorithm", "sha256-pairwise-v2",
       "a different value", ~w(bundle_shape)},
      {"exec_seed_other", :observed, :exec, "seed", V.other_hash(), "another seed",
       ~w(seed_recomputation)},
      {"exec_results_reversed", :observed, :exec, "results", :reverse, "winners reversed",
       ~w(winner_selection)},
      {"exec_signing_key_id_other", :observed, :exec, "signing_key_id", "deadbeef",
       "an unknown key", ~w(exec_signature)},
      {"exec_weather_station_not_middle_wallop", :observed, :exec, "weather_station", "wmo-03772",
       "a station other than Middle Wallop", ~w(bundle_shape receipt_field_consistency)},
      {"exec_weather_station_null", :observed, :exec, "weather_station", nil, "nil",
       ~w(bundle_shape receipt_field_consistency)},
      {"exec_weather_value_other", :observed, :exec, "weather_value", "142;1025;85;2432",
       "+1 tenth °C", ~w(drand_bls_signature seed_recomputation)},
      {"exec_weather_value_grammar", :observed, :exec, "weather_value", "-0;1025;85;2432",
       "off grammar", ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"exec_weather_observation_time_plus_hour", :observed, :exec, "weather_observation_time",
       rfc(add_h(wt, 1)), "+1 hour", ~w(weather_observation_window)},
      {"exec_weather_observation_time_null", :observed, :exec, "weather_observation_time", nil,
       "nil with a value",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_weather_observation_time_offset_utc", :observed, :exec, "weather_observation_time",
       offset(wt, 0), "a +00:00 offset", ~w(bundle_shape weather_observation_window)},
      {"exec_weather_observation_time_offset_bst", :observed, :exec, "weather_observation_time",
       offset(wt, 1), "the same instant at +01:00", ~w(bundle_shape weather_observation_window)},
      {"exec_weather_fallback_reason_on_observed", :observed, :exec, "weather_fallback_reason",
       Protocol.landobs_fallback_reason(), "a reason with a value",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_fallback_station_wittering", :fallback, :exec, "weather_station", "wmo-03462",
       "Wittering on a fallback", ~w(bundle_shape receipt_field_consistency)},
      {"exec_fallback_reason_v5", :fallback, :exec, "weather_fallback_reason", "unreachable",
       "a schema 4 reason",
       ~w(bundle_shape receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_fallback_reason_null", :fallback, :exec, "weather_fallback_reason", nil,
       "nil on a fallback",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_value_on_observed", :observed, :exec, "freq_value", @freq_value,
       "a window beside a reading",
       ~w(drand_bls_signature receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_fallback_reason_on_observed", :observed, :exec, "freq_fallback_reason",
       Protocol.freq_fallback_reason(), "the frequency reason beside a reading",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_reason_null_on_fallback", :fallback, :exec, "freq_fallback_reason", nil,
       "nil on a drand-only fallback",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_reason_other_on_fallback", :fallback, :exec, "freq_fallback_reason",
       "unreachable", "another reason on a drand-only fallback",
       ~w(bundle_shape receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_value_other_on_freq_window", :freq_fallback, :exec, "freq_value",
       "50013;50018;50012;49983;49980;49953;49912;49883", "first reading +1 mHz",
       ~w(drand_bls_signature seed_recomputation)},
      {"exec_freq_value_null_on_freq_window", :freq_fallback, :exec, "freq_value", nil,
       "nil with the weather reason and no freq reason",
       ~w(drand_bls_signature receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_fallback_reason_beside_value", :freq_fallback, :exec, "freq_fallback_reason",
       Protocol.freq_fallback_reason(), "the frequency reason beside a window",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_freq_value_grammar_on_freq_window", :freq_fallback, :exec, "freq_value",
       "50000;50000;50000;50000;50000;50000;50012;50013", "a stuck run of 6",
       ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"exec_weather_reason_null_on_freq_window", :freq_fallback, :exec,
       "weather_fallback_reason", nil, "nil beside a window",
       ~w(receipt_field_consistency seed_recomputation weather_observation_window)},
      {"exec_entropy_composition_freq", :observed, :exec, "entropy_composition", Freq.tag(),
       "the grid-frequency tag",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"exec_jcs_version_other", :observed, :exec, "jcs_version", "sha256-jcs-v2",
       "a different value", ~w(bundle_shape)},
      {"exec_signature_algorithm_other", :observed, :exec, "signature_algorithm", "ed448",
       "a different value", ~w(bundle_shape)},
      {"exec_sequence_float", :observed, :exec, "sequence", {:float, 7},
       "wrong type: 7.0 in the signed bytes",
       ~w(bundle_shape exec_signature receipt_field_consistency)},
      {"exec_drand_round_float", :observed, :exec, "drand_round", {:float, V.round()},
       "wrong type: a float in the signed bytes",
       ~w(bundle_shape exec_signature receipt_field_consistency)},
      {"exec_fair_pick_version_other", :observed, :exec, "fair_pick_version", "0.1.0",
       "another released version than the lock's", ~w(receipt_field_consistency)},
      {"exec_operator_slug_other", :observed, :exec, "operator_slug", "someone-else",
       "another slug than the lock's", ~w(receipt_field_consistency)},

      # ── Both receipts ─────────────────────────────────────────────
      {"both_fair_pick_version_unreleased", :observed, :both, "fair_pick_version", "0.2.1",
       "a fair_pick version never released, on both receipts", ~w(receipt_field_consistency)},
      {"both_fair_pick_version_unknown", :fallback, :both, "fair_pick_version", "9.9.9",
       "an unknown fair_pick version, on both receipts", ~w(receipt_field_consistency)}
    ]
  end

  defp rfc(dt), do: WallopCore.Time.to_rfc3339_usec(dt)

  # The same instant written with a +0h:00 offset instead of Z.
  defp offset(dt, h),
    do: dt |> DateTime.add(h * 3600) |> rfc() |> String.replace_suffix("Z", "+0#{h}:00")

  defp add_h(dt, n), do: DateTime.add(dt, n * 3600)
  defp add_us(dt, n), do: DateTime.add(dt, n, :microsecond)
end

defmodule WallopCore.TamperProfiles.Freq do
  @moduledoc """
  The grid-frequency tag's tamper profile. Same round as the Land Obs
  profile (33068212, published 2026-10-14T20:00:00Z), so T is 19:54:00
  and the latest lock is 19:53:00. The value is the real Elexon window for
  19:54:00 to 19:55:45 UTC.

  Its cases are the tag-independent Land Obs cases under a `freq_` prefix
  (the same mutation of a field both tags sign the same way), and the
  tag's own: `freq_start`, `freq_value`, `freq_fallback_reason`, the
  weather fields that must stay null, `locked_at` against T - 60 s, the
  round against T, the tag (on either receipt, so both cross-tag pairings)
  and the schema.
  """
  @behaviour WallopCore.TamperProfiles

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.TamperProfiles
  alias WallopCore.TamperVectors

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
  @locked_at ~U[2026-10-14 19:50:00.123456Z]

  # Land Obs cases whose field both tags sign with the same rule.
  @generic ~w(lock_draw_id_other lock_operator_id_other lock_sequence_plus_one
              lock_sequence_string lock_sequence_float lock_entry_hash_other
              lock_winner_count_plus_one lock_winner_count_float lock_signing_key_id_other
              lock_jcs_version_other lock_signature_algorithm_other lock_fair_pick_version_other
              lock_operator_slug_other lock_commitment_hash_other lock_commitment_hash_upper_case
              lock_drand_chain_mainnet
              exec_drand_round_plus_one exec_drand_round_minus_one exec_drand_round_float
              exec_drand_randomness_other exec_drand_signature_other exec_drand_chain_mainnet
              exec_drand_signature_algorithm_other exec_draw_id_other exec_operator_id_other
              exec_sequence_plus_one exec_sequence_float exec_entry_hash_other
              exec_executed_at_before_round exec_executed_at_not_canonical
              exec_executed_at_offset_utc exec_executed_at_offset_bst
              exec_lock_receipt_hash_other exec_merkle_algorithm_other exec_seed_other
              exec_results_reversed exec_signing_key_id_other exec_jcs_version_other
              exec_signature_algorithm_other exec_fair_pick_version_other exec_operator_slug_other
              both_fair_pick_version_unreleased both_fair_pick_version_unknown)

  @doc "The vectors' frequency value."
  def value, do: @value

  @impl true
  def tag, do: Freq.tag()
  @impl true
  def vector_file, do: "proof-bundle-v6-tamper-freq.json"
  @impl true
  def kinds, do: [:observed, :fallback]

  @impl true
  def description,
    do:
      "Signed lock v6 / execution v5 proof bundles under the grid-frequency tag " <>
        "#{Freq.tag()}, each with exactly one signed field tampered (on one " <>
        "receipt, or on both for receipt both) and re-signed with the vector key, " <>
        "so only the semantic checks can refuse it. When the lock receipt is " <>
        "tampered, the execution receipt's lock_receipt_hash is recomputed and " <>
        "re-signed too. Each case must fail exactly expected_failing_steps and " <>
        "never pass. The bases pass."

  @impl true
  def lock_keys, do: Freq.lock_keys()
  @impl true
  def exec_keys, do: Freq.exec_keys()
  @impl true
  def base_name(kind), do: "freq_#{kind}"
  @impl true
  def locked_at, do: @locked_at

  @impl true
  def lock_fields do
    %{
      entropy_composition: Freq.tag(),
      locked_at: @locked_at,
      weather_station: nil,
      weather_time: nil,
      freq_start: Schedule.freq_start_for_round(TamperVectors.round())
    }
  end

  @impl true
  def exec_fields(kind) do
    {value, reason} =
      if kind == :observed, do: {@value, nil}, else: {nil, Freq.fallback_reason()}

    %{
      weather_station: nil,
      weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: nil,
      freq_value: value,
      freq_fallback_reason: reason
    }
  end

  @impl true
  def seed(entry_hash, randomness, :observed),
    do: Protocol.compute_freq_seed(entry_hash, randomness, @value)

  def seed(entry_hash, randomness, :fallback), do: Protocol.compute_seed(entry_hash, randomness)

  @impl true
  def entropy(:observed), do: %{"freq_value" => @value}
  def entropy(:fallback), do: %{}

  @impl true
  def cases do
    generic =
      for {name, kind, receipt, field, value, mutation, steps} <- TamperProfiles.LandObs.cases(),
          name in @generic,
          do: {"freq_" <> name, kind, receipt, field, value, mutation, steps}

    generic ++ specific()
  end

  defp specific do
    round = TamperVectors.round()
    t = Schedule.freq_start_for_round(round)
    latest = Schedule.latest_lock_at(t)
    pub = Quicknet.pub_time(round)
    hour = ~U[2026-10-14 19:00:00.000000Z]
    unknown = "drand-quicknet+elexon-freq-v2"
    stuck = "50000;50000;50000;50000;50000;50000;50012;50013"
    seven = "50012;50018;50012;49983;49980;49953;49912"
    zero = "00000;50018;50012;49983;49980;49953;49912;49883"
    bumped = "50013;50018;50012;49983;49980;49953;49912;49883"
    low = "46999;50018;50012;49983;49980;49953;49912;49883"
    weather = "no_observation_by_deadline"

    [
      # ── Lock receipt ──────────────────────────────────────────────
      {"freq_lock_freq_start_plus_15s", :observed, :lock, "freq_start", rfc(add_s(t, 15)),
       "+15 s (another window start)", ~w(weather_observation_window)},
      {"freq_lock_freq_start_minus_15s", :observed, :lock, "freq_start", rfc(add_s(t, -15)),
       "-15 s (another window start)", ~w(weather_observation_window)},
      {"freq_lock_freq_start_plus_1s", :observed, :lock, "freq_start", rfc(add_s(t, 1)),
       "+1 s (off the 15 s grid)", ~w(bundle_shape weather_observation_window)},
      {"freq_lock_freq_start_null", :observed, :lock, "freq_start", nil, "nil",
       ~w(bundle_shape lock_signature weather_observation_window)},
      {"freq_lock_freq_start_not_canonical", :observed, :lock, "freq_start",
       "2026-10-14T19:54:00.000000+00:00", "a +00:00 offset",
       ~w(bundle_shape weather_observation_window)},
      {"freq_lock_freq_start_offset_bst", :observed, :lock, "freq_start",
       "2026-10-14T20:54:00.000000+01:00", "the same instant at +01:00",
       ~w(bundle_shape weather_observation_window)},
      {"freq_lock_locked_at_after_limit", :observed, :lock, "locked_at", rfc(add_us(latest, 1)),
       "T - 60 s + 1 µs", ~w(weather_observation_window)},
      {"freq_lock_locked_at_after_round", :observed, :lock, "locked_at", rfc(add_us(pub, 1)),
       "pub(R) + 1 µs", ~w(weather_observation_window drand_bls_signature)},
      {"freq_lock_locked_at_not_canonical", :observed, :lock, "locked_at",
       "2026-10-14T19:50:00.123456+00:00", "a +00:00 offset",
       ~w(bundle_shape drand_bls_signature temporal_binding weather_observation_window)},
      {"freq_lock_locked_at_offset_bst", :observed, :lock, "locked_at",
       "2026-10-14T20:50:00.123456+01:00", "the same instant at +01:00",
       ~w(bundle_shape drand_bls_signature temporal_binding weather_observation_window)},
      {"freq_lock_drand_round_plus_one", :observed, :lock, "drand_round", round + 1,
       "+1 round (the same window)", ~w(receipt_field_consistency)},
      {"freq_lock_drand_round_minus_one", :observed, :lock, "drand_round", round - 1,
       "-1 round (the window before)", ~w(receipt_field_consistency weather_observation_window)},
      {"freq_lock_drand_round_plus_five", :observed, :lock, "drand_round", round + 5,
       "+5 rounds (the next window)", ~w(receipt_field_consistency weather_observation_window)},
      {"freq_lock_drand_round_string", :observed, :lock, "drand_round", Integer.to_string(round),
       "wrong type: a string",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"freq_lock_drand_round_float", :observed, :lock, "drand_round", {:float, round},
       "wrong type: a float in the signed bytes",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"freq_lock_weather_station_set", :observed, :lock, "weather_station", "wmo-03749",
       "a weather station", ~w(bundle_shape receipt_field_consistency)},
      {"freq_lock_weather_time_set", :observed, :lock, "weather_time", rfc(hour),
       "a weather hour", ~w(bundle_shape)},
      {"freq_lock_entropy_composition_landobs", :observed, :lock, "entropy_composition",
       LandObs.tag(), "the Land Obs tag (a Land Obs lock with a frequency exec)",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"freq_lock_entropy_composition_forecast", :observed, :lock, "entropy_composition",
       TamperVectors.forecast_tag(), "the forecast tag",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"freq_lock_entropy_composition_unknown", :observed, :lock, "entropy_composition", unknown,
       "an unknown tag",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},
      {"freq_lock_schema_version_5", :observed, :lock, "schema_version", "5",
       "a different schema",
       ~w(bundle_shape lock_signature receipt_field_consistency weather_observation_window)},

      # ── Execution receipt ─────────────────────────────────────────
      {"freq_exec_freq_value_plus_one", :observed, :exec, "freq_value", bumped,
       "first reading +1 mHz", ~w(drand_bls_signature seed_recomputation)},
      {"freq_exec_freq_value_stuck", :observed, :exec, "freq_value", stuck, "a stuck run of 6",
       ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"freq_exec_freq_value_zero", :observed, :exec, "freq_value", zero, "a zero reading",
       ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"freq_exec_freq_value_out_of_bounds", :observed, :exec, "freq_value", low,
       "a reading below 47000 mHz", ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"freq_exec_freq_value_seven", :observed, :exec, "freq_value", seven, "seven readings",
       ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"freq_exec_freq_value_number", :observed, :exec, "freq_value", 50_012,
       "wrong type: a number", ~w(bundle_shape exec_signature)},
      {"freq_exec_freq_value_null", :observed, :exec, "freq_value", nil, "nil with no reason",
       ~w(drand_bls_signature seed_recomputation weather_observation_window)},
      {"freq_exec_reason_beside_value", :observed, :exec, "freq_fallback_reason",
       Freq.fallback_reason(), "a reason with a value", ~w(weather_observation_window)},
      {"freq_exec_weather_value_set", :observed, :exec, "weather_value", "141;1025;85;2432",
       "a weather value", ~w(bundle_shape drand_bls_signature seed_recomputation)},
      {"freq_exec_weather_station_set", :observed, :exec, "weather_station", "wmo-03749",
       "a weather station", ~w(bundle_shape receipt_field_consistency)},
      {"freq_exec_weather_observation_time_set", :observed, :exec, "weather_observation_time",
       rfc(hour), "a weather hour", ~w(bundle_shape)},
      {"freq_exec_weather_fallback_reason_set", :observed, :exec, "weather_fallback_reason",
       weather, "the weather reason beside a frequency value", ~w(bundle_shape)},
      # The exec signature verifies: the harness re-signs the mutated bytes,
      # and the receipt still parses because both tags share one exec key
      # set. Rejection comes from bundle_shape, receipt_field_consistency
      # and weather_observation_window.
      {"freq_exec_entropy_composition_landobs", :observed, :exec, "entropy_composition",
       LandObs.tag(), "the Land Obs tag (a frequency lock with a Land Obs exec)",
       ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"freq_exec_entropy_composition_unknown", :observed, :exec, "entropy_composition", unknown,
       "an unknown tag", ~w(bundle_shape receipt_field_consistency weather_observation_window)},
      {"freq_exec_schema_version_4", :observed, :exec, "schema_version", "4",
       "a different schema",
       ~w(bundle_shape exec_signature receipt_field_consistency weather_observation_window)},

      # ── Fallback ──────────────────────────────────────────────────
      {"freq_fallback_reason_null", :fallback, :exec, "freq_fallback_reason", nil,
       "nil on a fallback", ~w(weather_observation_window)},
      {"freq_fallback_reason_weather", :fallback, :exec, "freq_fallback_reason", weather,
       "the weather reason", ~w(bundle_shape weather_observation_window)},
      {"freq_fallback_value_set", :fallback, :exec, "freq_value", @value,
       "a value beside the reason",
       ~w(drand_bls_signature seed_recomputation weather_observation_window)},
      {"freq_fallback_weather_reason_set", :fallback, :exec, "weather_fallback_reason", weather,
       "the weather reason in the weather field", ~w(bundle_shape)},
      {"freq_fallback_weather_value_set", :fallback, :exec, "weather_value", "141;1025;85;2432",
       "a weather value on a fallback", ~w(bundle_shape drand_bls_signature seed_recomputation)}
    ]
  end

  defp rfc(dt), do: WallopCore.Time.to_rfc3339_usec(dt)
  defp add_s(dt, n), do: DateTime.add(dt, n)
  defp add_us(dt, n), do: DateTime.add(dt, n, :microsecond)
end
