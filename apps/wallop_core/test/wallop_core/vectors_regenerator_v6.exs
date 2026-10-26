# Generates the lock v6 / execution v5 shared vectors for both entropy tags.
# Run with:
#
#   MIX_ENV=test mix run apps/wallop_core/test/wallop_core/vectors_regenerator_v6.exs
#
# Writes (in spec/vectors/):
#
#   drand-quicknet+metoffice-landobs-v1 (observation weather):
#     weather-schedule-landobs-v1.json, weather-value-landobs-v1.json,
#     lock-receipt-v6.json, execution-receipt-v5.json (state a),
#     execution-receipt-freq-window-v5.json (state b),
#     execution-receipt-fallback-v5.json (state c),
#     proof-bundle-v6.json, proof-bundle-v6-freq-window.json,
#     proof-bundle-v6-fallback.json
#
#   drand-quicknet+elexon-freq-v1 (grid frequency):
#     frequency-schedule-elexon-v1.json, frequency-value-elexon-v1.json,
#     lock-receipt-v6-freq.json, execution-receipt-v5-freq.json,
#     execution-receipt-fallback-v5-freq.json, proof-bundle-v6-freq.json,
#     proof-bundle-v6-freq-fallback.json
#
#   both tags: proof-bundle-v6-negative.json
#
# Pure: no database, no network. Every receipt comes from the real builders
# (`Protocol.build_v6_lock_payload/1`, `Protocol.build_v6_execution_payload/1`),
# which refuse any input the tag's rules don't allow, and every bundle from
# `WallopCore.ProofBundle.assemble/1`. Both receipts are signed with the
# deterministic vector keys (`WallopCore.TamperVectors`).
#
# A negative case starts from a positive bundle, changes signed fields, and
# signs again, so the signatures are valid over the bytes as written (cases
# that change only a wrapper key or the unsigned entropy are not re-signed). A changed lock gets
# a recomputed `lock_receipt_hash` in the execution receipt. The seed, the
# results and the unsigned entropy block are rebuilt from the changed receipt
# the way the verifier's own fixtures build them (see `seed_for/2`).

defmodule WallopCore.VectorsV6 do
  @moduledoc false

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.FreqGrammar
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs, as: LandObsTag
  alias WallopCore.TamperVectors, as: Keys
  alias WallopCore.Weather.{LandObsGrammar, Schedule, Stations}

  @dir Path.expand("../../../../spec/vectors", __DIR__)

  @landobs "drand-quicknet+metoffice-landobs-v1"
  @freq "drand-quicknet+elexon-freq-v1"
  @forecast "drand-quicknet+openmeteo-v1"
  @no_observation "no_observation_by_deadline"
  @no_frequency "no_frequency_by_deadline"

  # Quicknet round 33068212, published 2026-10-14T20:00:00Z.
  @round 33_068_212
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

  @landobs_locked_at ~U[2026-10-14 18:00:00.123456Z]
  @freq_locked_at ~U[2026-10-14 19:50:00.123456Z]
  @executed_at ~U[2026-10-14 20:00:05.000000Z]
  @key_inserted_at "2026-10-01T00:00:00.000000Z"

  @draw_id "66666666-6666-4666-8666-666666666666"
  @operator_id "11111111-1111-4111-8111-111111111111"
  @entries for n <- 1..5, do: "00000000-0000-4000-8000-00000000000#{n}"
  @winner_count 2

  # The weather value of state (a), from the synthetic 19:00 UTC row below
  # (12.34 C, 1012 hPa, 67 %, 34500 m).
  @weather_value "123;1012;67;3450"
  # The Elexon FREQ window 19:54:00-19:55:45 UTC, in time order.
  @freq_value "50012;50018;50012;49983;49980;49953;49912;49883"

  def run do
    true = sha256_hex(Base.decode16!(@signature, case: :lower)) == @randomness

    write_landobs()
    write_freq()
    write("proof-bundle-v6-negative.json", negative_vector())
  end

  # ── Shared ────────────────────────────────────────────────────────

  defp keys do
    {_, op_pub, op_kid} = Keys.operator_key()
    {_, infra_pub, infra_kid} = Keys.infrastructure_key()

    [
      %{
        "key_id" => op_kid,
        "public_key_hex" => hex(op_pub),
        "key_class" => "operator",
        "inserted_at" => @key_inserted_at
      },
      %{
        "key_id" => infra_kid,
        "public_key_hex" => hex(infra_pub),
        "key_class" => "infrastructure",
        "inserted_at" => @key_inserted_at
      }
    ]
  end

  defp entry_hash do
    {hash, _} = Protocol.entry_hash({@draw_id, Enum.map(@entries, &%{uuid: &1, weight: 1})})
    hash
  end

  defp lock_input(tag) do
    {_, _, kid} = Keys.operator_key()

    {locked_at, station, weather_time} =
      case tag do
        @landobs ->
          {@landobs_locked_at, Stations.primary().id, Schedule.weather_time_for_round(@round)}

        @freq ->
          {@freq_locked_at, nil, nil}
      end

    %{
      entropy_composition: tag,
      operator_id: @operator_id,
      operator_slug: "acme-prizes",
      sequence: 1,
      draw_id: @draw_id,
      commitment_hash: entry_hash(),
      entry_hash: entry_hash(),
      locked_at: locked_at,
      signing_key_id: kid,
      winner_count: @winner_count,
      drand_chain: Quicknet.chain_hash(),
      drand_round: @round,
      weather_station: station,
      weather_time: weather_time,
      freq_start: FreqSchedule.freq_start_for_round(@round),
      wallop_core_version: "0.29.0",
      fair_pick_version: Keys.fair_pick_version()
    }
  end

  # The five fields of the three-state table, for each base.
  defp five(:a),
    do: %{
      weather_value: @weather_value,
      weather_observation_time: Schedule.weather_time_for_round(@round),
      weather_fallback_reason: nil,
      freq_value: nil,
      freq_fallback_reason: nil
    }

  defp five(:b),
    do:
      %{five(:a) | weather_value: nil, weather_observation_time: nil}
      |> Map.merge(%{weather_fallback_reason: @no_observation, freq_value: @freq_value})

  defp five(:c), do: %{five(:b) | freq_value: nil, freq_fallback_reason: @no_frequency}

  defp five(:freq_value),
    do: %{
      weather_value: nil,
      weather_observation_time: nil,
      weather_fallback_reason: nil,
      freq_value: @freq_value,
      freq_fallback_reason: nil
    }

  defp five(:freq_fallback),
    do: %{five(:freq_value) | freq_value: nil, freq_fallback_reason: @no_frequency}

  defp tag_of(base) when base in [:a, :b, :c], do: @landobs
  defp tag_of(_), do: @freq

  defp exec_input(base, lock_jcs) do
    {_, _, kid} = Keys.infrastructure_key()
    lock = lock_input(tag_of(base))
    fields = five(base)
    exec = Map.new(fields, fn {k, v} -> {Atom.to_string(k), v} end)
    {seed, winners} = seed_and_winners(seed_for(exec, rule(base)))

    Map.merge(fields, %{
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
      weather_station: lock.weather_station,
      wallop_core_version: lock.wallop_core_version,
      fair_pick_version: lock.fair_pick_version,
      seed: hex(seed),
      results: Enum.map(winners, & &1.entry_id),
      executed_at: @executed_at,
      signing_key_id: kid
    })
  end

  defp rule(base) when base in [:a, :b, :c], do: :landobs
  defp rule(_), do: :freq

  @doc false
  # {lock_input, lock_jcs, exec_input, exec_jcs} for a positive base.
  def base(base) do
    lock = lock_input(tag_of(base))
    lock_jcs = Protocol.build_v6_lock_payload(lock)
    exec = exec_input(base, lock_jcs)
    {lock, lock_jcs, exec, Protocol.build_v6_execution_payload(exec)}
  end

  # The seed a bundle carries, from its signed execution receipt (a string
  # keyed map). Mirrors the verifier's fixture builders:
  #
  #   * :landobs (`build_v6_bundle`): under the Land Obs tag, a receipt in
  #     the three-state table takes its state's seed; otherwise (another tag,
  #     or out of the table) the first non-null of weather_value, freq_value,
  #     then drand alone. The verifier refuses an out-of-table receipt
  #     whatever its seed.
  #   * :freq (`build_freq_bundle`): freq_value, or drand alone if it is
  #     null. Never weather_value.
  defp seed_for(exec, :landobs) do
    case landobs_state(exec) do
      {:ok, :weather} -> {:weather, exec["weather_value"]}
      {:ok, :frequency} -> {:freq, exec["freq_value"]}
      {:ok, :drand_only} -> :drand
      :error -> first_non_null(exec)
    end
  end

  defp seed_for(exec, :freq) do
    if exec["freq_value"], do: {:freq, exec["freq_value"]}, else: :drand
  end

  defp landobs_state(%{"entropy_composition" => @landobs} = exec) do
    keys = ~w(weather_value weather_observation_time weather_fallback_reason freq_value
              freq_fallback_reason)

    if Enum.all?(keys, &Map.has_key?(exec, &1)) do
      LandObsTag.exec_state(%{
        weather_value: exec["weather_value"],
        weather_observation_time: exec["weather_observation_time"] && DateTime.utc_now(),
        weather_fallback_reason: exec["weather_fallback_reason"],
        freq_value: exec["freq_value"],
        freq_fallback_reason: exec["freq_fallback_reason"]
      })
    else
      :error
    end
  end

  defp landobs_state(_exec), do: :error

  defp first_non_null(exec) do
    cond do
      exec["weather_value"] -> {:weather, exec["weather_value"]}
      exec["freq_value"] -> {:freq, exec["freq_value"]}
      true -> :drand
    end
  end

  defp seed_and_winners(source) do
    {seed, _} =
      case source do
        {:weather, value} -> Protocol.compute_seed(entry_hash(), @randomness, value)
        {:freq, value} -> Protocol.compute_freq_seed(entry_hash(), @randomness, value)
        :drand -> Protocol.compute_seed(entry_hash(), @randomness)
      end

    {seed, FairPick.draw(Enum.map(@entries, &%{id: &1, weight: 1}), seed, @winner_count)}
  end

  # The bundle (JCS text) around a lock and an execution payload: signs both
  # and takes the results from the receipt's own seed.
  defp bundle(lock_jcs, exec_jcs, opts \\ []) do
    {op_sk, op_pub, _} = Keys.operator_key()
    {infra_sk, infra_pub, _} = Keys.infrastructure_key()
    exec = Jason.decode!(exec_jcs)

    winners =
      FairPick.draw(
        Enum.map(@entries, &%{id: &1, weight: 1}),
        Base.decode16!(exec["seed"], case: :lower),
        @winner_count
      )

    true = Enum.map(winners, & &1.entry_id) == exec["results"]

    entropy =
      Keyword.get_lazy(opts, :entropy, fn -> entropy_for(exec) end)

    WallopCore.ProofBundle.assemble(%{
      draw_id: @draw_id,
      entries: Enum.map(@entries, &%{"uuid" => &1, "weight" => 1}),
      results: Enum.map(winners, &%{"entry_id" => &1.entry_id, "position" => &1.position}),
      entropy: entropy,
      lock_receipt: {lock_jcs, Protocol.sign_receipt(lock_jcs, op_sk)},
      execution_receipt: {exec_jcs, Protocol.sign_receipt(exec_jcs, infra_sk)},
      inline_keys: %{
        lock: if(opts[:inline_lock_key], do: hex(op_pub)),
        exec: if(opts[:inline_exec_key], do: hex(infra_pub))
      }
    })
  end

  # The unsigned entropy block: the beacon, and every non-null value the
  # execution receipt signs.
  defp entropy_for(exec) do
    %{
      "drand_round" => exec["drand_round"],
      "drand_randomness" => exec["drand_randomness"],
      "drand_signature" => exec["drand_signature"],
      "drand_chain_hash" => exec["drand_chain"]
    }
    |> put_present("weather_value", exec["weather_value"])
    |> put_present("freq_value", exec["freq_value"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp receipt_vector(description, input, jcs) do
    payload = Jason.decode!(jcs)

    %{
      "description" => description,
      "expected_field_count" => map_size(payload),
      "expected_schema_version" => payload["schema_version"],
      "expected_payload_sha256" => sha256_hex(jcs),
      "payload_jcs" => jcs,
      "input" => stringify_input(input)
    }
  end

  defp stringify_input(input) do
    Map.new(input, fn
      {k, %DateTime{} = dt} -> {Atom.to_string(k), usec(dt)}
      {k, v} -> {Atom.to_string(k), v}
    end)
  end

  defp bundle_vector(description, bundle_jcs) do
    %{
      "description" => description,
      "bundle" => bundle_jcs,
      "keys" => keys(),
      "expected_passed" => true
    }
  end

  # ── Observation weather (drand-quicknet+metoffice-landobs-v1) ─────

  @state_text %{
    a: "a Middle Wallop observation for the round's hour fed the seed",
    b:
      "no Middle Wallop observation by the deadline, so the round's grid-frequency window fed the seed",
    c:
      "no Middle Wallop observation by the deadline and no grid-frequency window, so drand alone fed the seed"
  }

  defp bundle_note(:a), do: " The weather value is invented test data, not a real observation."
  defp bundle_note(_state), do: ""

  defp state_prefix(state), do: "#{@landobs}, state (#{state}): "

  defp write_landobs do
    write("weather-schedule-landobs-v1.json", landobs_schedule())
    write_raw("weather-value-landobs-v1.json", landobs_value_file())

    {lock, lock_jcs, _, _} = base(:a)

    write(
      "lock-receipt-v6.json",
      receipt_vector(
        "#{@landobs}: lock receipt, schema 6, 20 fields. Middle Wallop (wmo-03749), " <>
          "weather_time 19:00 UTC and freq_start 19:54:00 UTC, both derived from quicknet " <>
          "round 33068212 (published 2026-10-14T20:00:00Z); locked_at is before " <>
          "weather_time minus 46 minutes. input is the builder input; payload_jcs is the " <>
          "signed payload.",
        lock,
        lock_jcs
      )
    )

    for {state, receipt_file, bundle_file} <- [
          {:a, "execution-receipt-v5.json", "proof-bundle-v6.json"},
          {:b, "execution-receipt-freq-window-v5.json", "proof-bundle-v6-freq-window.json"},
          {:c, "execution-receipt-fallback-v5.json", "proof-bundle-v6-fallback.json"}
        ] do
      {_, ^lock_jcs, exec, exec_jcs} = base(state)

      write(
        receipt_file,
        receipt_vector(
          state_prefix(state) <>
            "#{@state_text[state]}. Execution receipt, schema 5, 28 fields, " <>
            "weather_station wmo-03749. #{state_fields(state)}",
          exec,
          exec_jcs
        )
      )

      write(
        bundle_file,
        bundle_vector(
          state_prefix(state) <>
            "#{@state_text[state]}.#{bundle_note(state)} A passing proof bundle: " <>
            "lock-receipt-v6.json and " <>
            "#{receipt_file}, signed by the keys in keys, on quicknet round 33068212 " <>
            "with its real beacon. Every verifier step must pass.",
          bundle(lock_jcs, exec_jcs)
        )
      )
    end
  end

  defp state_fields(:a),
    do:
      "weather_value 123;1012;67;3450 (invented test data, not a real observation) with its " <>
        "observation time; both reasons and freq_value null. " <>
        "Seed: compute_seed(entry_hash, drand_randomness, weather_value)."

  defp state_fields(:b),
    do:
      "Weather value and time null, weather_fallback_reason #{@no_observation}, freq_value " <>
        "the Elexon window 19:54:00-19:55:45 UTC, freq_fallback_reason null. Seed: " <>
        "compute_freq_seed(entry_hash, drand_randomness, freq_value). The landobs tag's " <>
        "state (b), not the grid-frequency tag."

  defp state_fields(:c),
    do:
      "Weather value and time null, weather_fallback_reason #{@no_observation}, freq_value " <>
        "null, freq_fallback_reason #{@no_frequency}. Seed: compute_seed(entry_hash, " <>
        "drand_randomness)."

  defp landobs_schedule do
    w = Schedule.fetch_window_seconds()
    h = ~U[2026-10-14 19:00:00Z]
    at_bound = div(DateTime.to_unix(h) + w + 60 - Quicknet.genesis(), Quicknet.period()) + 1

    # The at-bound round publishes exactly at h + W + 60 s, so its weather_time is h.
    true = DateTime.compare(Quicknet.pub_time(at_bound), DateTime.add(h, w + 60)) == :eq
    true = DateTime.compare(Schedule.weather_time_for_round(at_bound), h) == :eq

    expected = [
      {33_067_632, "2026-10-14T19:31:00.000000Z", "2026-10-14T19:00:00.000000Z",
       "2026-10-14T18:14:00.000000Z", "2026-10-14T19:25:00.000000Z"},
      {33_067_631, "2026-10-14T19:30:57.000000Z", "2026-10-14T18:00:00.000000Z",
       "2026-10-14T17:14:00.000000Z", "2026-10-14T19:24:45.000000Z"},
      {33_068_212, "2026-10-14T20:00:00.000000Z", "2026-10-14T19:00:00.000000Z",
       "2026-10-14T18:14:00.000000Z", "2026-10-14T19:54:00.000000Z"},
      {33_068_352, "2026-10-14T20:07:00.000000Z", "2026-10-14T19:00:00.000000Z",
       "2026-10-14T18:14:00.000000Z", "2026-10-14T20:01:00.000000Z"},
      {33_068_912, "2026-10-14T20:35:00.000000Z", "2026-10-14T20:00:00.000000Z",
       "2026-10-14T19:14:00.000000Z", "2026-10-14T20:29:00.000000Z"}
    ]

    {33_067_632, _, _, _, _} = hd(expected)
    true = at_bound == 33_067_632

    cases =
      for {round, _, _, _, _} = row <- expected do
        wt = Schedule.weather_time_for_round(round)

        computed =
          {round, usec(Quicknet.pub_time(round)), usec(wt), usec(Schedule.latest_lock_at(wt)),
           usec(FreqSchedule.freq_start_for_round(round))}

        if computed != row, do: raise("schedule case differs: #{inspect({computed, row})}")

        {^round, published, weather_time, latest, freq_start} = computed

        %{
          "drand_round" => round,
          "published_at" => published,
          "weather_time" => weather_time,
          "latest_lock_at" => latest,
          "freq_start" => freq_start
        }
      end

    %{
      "description" =>
        "#{@landobs}: the draw schedule. For a quicknet round, weather_time is the latest " <>
          "whole UTC hour h with h + w_secs + publish_margin_secs <= published_at; " <>
          "latest_lock_at is weather_time - lock_offset_secs; freq_start is the round's " <>
          "grid-frequency window start (the window state (b) uses). Cases: the round " <>
          "exactly at the bound (33067632), the round before it, mid-hour rounds, and " <>
          "33068912, whose weather_time is 20:00 under W = 30 min but would be 19:00 under " <>
          "W = 40 min.",
      "entropy_composition" => @landobs,
      "stations" => Stations.ids(),
      "w_secs" => w,
      "publish_margin_secs" => 60,
      "lock_offset_secs" => Schedule.lock_offset_seconds(),
      "cases" => cases
    }
  end

  # ── weather-value-landobs-v1.json ─────────────────────────────────

  @valid_values [
    {"173;1017;72;5237", [173, 1017, 72, 5237]},
    {"-900;850;0;0", [-900, 850, 0, 0]},
    {"600;1100;100;10000", [600, 1100, 100, 10_000]},
    {"0;1000;50;0", [0, 1000, 50, 0]},
    {"123;1012;67;3450", [123, 1012, 67, 3450]},
    {"184;1021;51;4114", [184, 1021, 51, 4114]},
    {"-35;998;100;0", [-35, 998, 100, 0]}
  ]

  @invalid_values [
    {"-0;1017;72;5237", "minus_zero"},
    {"0173;1017;72;5237", "leading_zero"},
    {"173;1017;72", "three_parts"},
    {"173;-1017;72;5237", "negative_mslp"},
    {"173;1017;72;5237;1", "five_parts"},
    {" 173;1017;72;5237", "leading_space"},
    {"173;1017;72;5237 ", "trailing_space"},
    {"173;1017;72;5237\n", "trailing_newline"},
    {"601;1017;72;5237", "t_above_bound"},
    {"-901;1017;72;5237", "t_below_bound"},
    {"173;849;72;5237", "mslp_below_bound"},
    {"173;1101;72;5237", "mslp_above_bound"},
    {"173;1017;101;5237", "rh_above_bound"},
    {"173;1017;72;10001", "vis_above_bound"},
    {"173;1017;-1;5237", "rh_below_bound: must not be negative (grammar)"},
    {"173;1017;72;-1", "vis_below_bound: must not be negative (grammar)"},
    {"", "empty"},
    {";;;", "empty_parts"},
    {"+184;1021;51;4114", "plus_sign"},
    {"18.4;1021;51;4114", "decimal_point"},
    {"1e2;1021;51;4114", "exponent"},
    {"184,1021,51,4114", "comma_separator"},
    {"１８４;1021;51;4114", "non_ascii_digits"},
    {"--1;1021;51;4114", "double_minus"},
    {"-;1021;51;4114", "bare_minus"},
    {"184;1021;051;4114", "leading_zero_rh"},
    {"00;1021;51;4114", "double_zero"},
    {"-00;1021;51;4114", "minus_double_zero"},
    {"184;1021;51;-0", "vis_minus_zero"},
    {"184;;51;4114", "empty_part"}
  ]

  # Synthetic rows, made in the format the Met Office Weather DataHub
  # documents for Land Observations (same field names, number formatting and
  # datetime format). None is a real observation. {key, JSON text} pairs.
  @row_1900 [
    {"temperature", "12.34"},
    {"visibility", "34500.0"},
    {"weather_code", "7"},
    {"datetime", ~s("2026-10-14T19:00:00Z")},
    {"humidity", "67"},
    {"mslp", "1012"},
    {"wind_gust", "7.4"},
    {"wind_speed", "3.6"},
    {"pressure_tendency", ~s("S")},
    {"wind_direction", ~s("SSW")}
  ]

  @row_1200 [
    {"datetime", ~s("2026-10-15T12:00:00Z")},
    {"humidity", "72"},
    {"mslp", "1017"},
    {"pressure_tendency", ~s("F")},
    {"temperature", "17.26"},
    {"visibility", "52370.0"},
    {"weather_code", "3"},
    {"wind_direction", ~s("W")},
    {"wind_gust", "10.8"},
    {"wind_speed", "6.1"}
  ]

  # A synthetic night-time row in a different key order.
  @row_0100 [
    {"mslp", "1003"},
    {"weather_code", "7"},
    {"wind_direction", ~s("WSW")},
    {"datetime", ~s("2026-10-25T01:00:00Z")},
    {"humidity", "79"},
    {"wind_gust", "11.3"},
    {"wind_speed", "5.9"},
    {"visibility", "15840.0"},
    {"temperature", "10.38"},
    {"pressure_tendency", ~s("R")}
  ]

  # {field, JSON text, expected part or :error}; each changes one field of
  # the 12:00 row (173;1017;72;5237).
  @single_field [
    {"temperature", "19.59", 196},
    {"temperature", "19.55", 196},
    {"temperature", "19.549", 195},
    {"temperature", "-0.05", -1},
    {"temperature", "-0.04", 0},
    {"temperature", "-12.35", -124},
    {"temperature", "7", 70},
    {"temperature", "60.0", 600},
    {"temperature", "-90.0", -900},
    {"temperature", "60.1", :error},
    {"temperature", "-90.1", :error},
    {"temperature", "60.04", 600},
    {"temperature", "60.05", :error},
    {"temperature", "1.959e1", :error},
    {"visibility", "41140.0", 4114},
    {"visibility", "41145", 4115},
    {"visibility", "25", 3},
    {"visibility", "0", 0},
    {"visibility", "100000", 10_000},
    {"visibility", "41140.5", :error},
    {"visibility", "52370.5", :error},
    {"visibility", "100010", :error},
    {"visibility", "100004", 10_000},
    {"visibility", "100005", :error},
    {"visibility", "-4", :error},
    {"mslp", "1021.0", 1021},
    {"mslp", "850", 850},
    {"mslp", "1100", 1100},
    {"mslp", "1020.4", :error},
    {"mslp", "849", :error},
    {"mslp", "1101", :error},
    {"mslp", "1.02E3", :error},
    {"mslp", "-0.0", :error},
    {"humidity", "0", 0},
    {"humidity", "100", 100},
    {"humidity", "76.5", :error},
    {"humidity", "101", :error},
    {"humidity", "-0", :error},
    # Fields the grammar never reads.
    {"wind_speed", "4e0", :unchanged},
    {"wind_gust", "1e400", :unchanged}
  ]

  @parts %{"temperature" => 0, "mslp" => 1, "humidity" => 2, "visibility" => 3}

  defp landobs_value_file do
    from_row =
      [
        {@row_1900, {:ok, "123;1012;67;3450"}},
        {@row_1200, {:ok, "173;1017;72;5237"}},
        {@row_0100, {:ok, "104;1003;79;1584"}}
      ] ++
        Enum.map(@single_field, fn {field, text, want} ->
          {put_row(@row_1200, field, text), single_field_expectation(field, want)}
        end) ++
        for field <- ["temperature", "mslp", "humidity", "visibility"],
            change <- [:missing, "null", ~s("20")] do
          row =
            if change == :missing,
              do: List.keydelete(@row_1200, field, 0),
              else: put_row(@row_1200, field, change)

          {row, :error}
        end

    from_row_text =
      Enum.map_join(from_row, ",\n    ", fn {row, want} ->
        result =
          case want do
            {:ok, value} -> ~s("expected_value": "#{value}")
            :error -> ~s("expected_error": true)
          end

        ~s({"row": #{row_text(row)}, #{result}})
      end)

    head = %{
      "description" =>
        "#{@landobs}: the weather_value grammar \"<t>;<mslp>;<rh>;<vis>\" (tenths of a " <>
          "degree C, whole hPa, whole percent, decametres) and how a Land Observations row " <>
          "becomes one. bounds apply to each part after rounding. valid values carry their " <>
          "parts; every invalid value must be refused. from_row: each row is raw JSON text; " <>
          "read it with a parser that keeps each number's text (60.0 and 60 differ, " <>
          "exponents are refused, 1e400 in a field nobody reads is fine). A float-based " <>
          "JSON reader does not test the grammar. Every row is synthetic, made in the format " <>
          "the Met Office Weather DataHub documents for Land Observations; none is a real " <>
          "observation. The single-field cases change one field of the 2026-10-15T12:00Z row.",
      "bounds" => %{
        "t" => [-900, 600],
        "mslp" => [850, 1100],
        "rh" => [0, 100],
        "vis" => [0, 10_000]
      },
      "valid" =>
        for {value, [t, mslp, rh, vis]} <- @valid_values do
          %{"value" => value, "t" => t, "mslp" => mslp, "rh" => rh, "vis" => vis}
        end,
      "invalid" =>
        for({value, reason} <- @invalid_values, do: %{"value" => value, "reason" => reason}),
      "from_row" => "@@FROM_ROW@@"
    }

    b = LandObsGrammar.bounds()
    true = {b.t, b.mslp, b.rh, b.vis} == {-900..600, 850..1100, 0..100, 0..10_000}

    for {value, _} <- @valid_values, do: true = LandObsGrammar.valid_value?(value)
    for {value, _} <- @invalid_values, do: false = LandObsGrammar.valid_value?(value)

    text =
      head
      |> encode()
      |> String.replace(~s("@@FROM_ROW@@"), "[\n    " <> from_row_text <> "\n  ]")

    check_from_row!(text, from_row)
    text
  end

  defp single_field_expectation(_field, :error), do: :error
  defp single_field_expectation(_field, :unchanged), do: {:ok, "173;1017;72;5237"}

  defp single_field_expectation(field, part) do
    parts = String.split("173;1017;72;5237", ";")
    {:ok, parts |> List.replace_at(@parts[field], Integer.to_string(part)) |> Enum.join(";")}
  end

  defp put_row(row, field, text), do: List.keystore(row, field, 0, {field, text})

  defp row_text(row),
    do: "{" <> Enum.map_join(row, ", ", fn {k, v} -> ~s("#{k}": #{v}) end) <> "}"

  # Reads the written text back with the grammar's own decoder: no number
  # text was normalised on the way out, and core agrees with every case.
  defp check_from_row!(text, from_row) do
    {:ok, decoded} = LandObsGrammar.decode(text)
    true = length(decoded["from_row"]) == length(from_row)

    for {c, {_row, want}} <- Enum.zip(decoded["from_row"], from_row) do
      got = LandObsGrammar.canonical_value(c["row"])

      ok? =
        case want do
          {:ok, value} -> got == {:ok, value} and c["expected_value"] == value
          :error -> match?({:error, _}, got) and c["expected_error"] == true
        end

      unless ok?, do: raise("from_row case disagrees with core: #{inspect({c, got})}")
    end
  end

  # ── Grid frequency (drand-quicknet+elexon-freq-v1) ────────────────

  defp write_freq do
    write("frequency-schedule-elexon-v1.json", freq_schedule())
    write("frequency-value-elexon-v1.json", freq_value_file())

    {lock, lock_jcs, _, _} = base(:freq_value)

    write(
      "lock-receipt-v6-freq.json",
      receipt_vector(
        "#{@freq}: lock receipt, schema 6, 20 fields. freq_start 19:54:00 UTC, derived from " <>
          "quicknet round 33068212 (published 2026-10-14T20:00:00Z); weather_station and " <>
          "weather_time null; locked_at is before freq_start minus 60 s. input is the " <>
          "builder input; payload_jcs is the signed payload.",
        lock,
        lock_jcs
      )
    )

    for {base, receipt_file, bundle_file, text} <- [
          {:freq_value, "execution-receipt-v5-freq.json", "proof-bundle-v6-freq.json",
           "the Elexon window 19:54:00-19:55:45 UTC fed the seed: freq_value set, " <>
             "freq_fallback_reason null. Seed: compute_freq_seed(entry_hash, " <>
             "drand_randomness, freq_value)"},
          {:freq_fallback, "execution-receipt-fallback-v5-freq.json",
           "proof-bundle-v6-freq-fallback.json",
           "no window by the deadline, so drand alone fed the seed: freq_value null, " <>
             "freq_fallback_reason #{@no_frequency}. Seed: compute_seed(entry_hash, " <>
             "drand_randomness)"}
        ] do
      {_, ^lock_jcs, exec, exec_jcs} = base(base)

      write(
        receipt_file,
        receipt_vector(
          "#{@freq}: execution receipt, schema 5, 28 fields; #{text}. Every weather " <>
            "field is null.",
          exec,
          exec_jcs
        )
      )

      write(
        bundle_file,
        bundle_vector(
          "#{@freq}: a passing proof bundle; #{text}. lock-receipt-v6-freq.json and " <>
            "#{receipt_file}, signed by the keys in keys, on quicknet round 33068212 with " <>
            "its real beacon. Every verifier step must pass.",
          bundle(lock_jcs, exec_jcs)
        )
      )
    end
  end

  defp freq_schedule do
    expected = [
      {33_068_212, "2026-10-14T20:00:00.000000Z", "2026-10-14T19:54:00.000000Z",
       "2026-10-14T19:59:45.000000Z", "2026-10-14T19:53:00.000000Z"},
      {33_068_211, "2026-10-14T19:59:57.000000Z", "2026-10-14T19:53:45.000000Z",
       "2026-10-14T19:59:30.000000Z", "2026-10-14T19:52:45.000000Z"},
      {33_068_213, "2026-10-14T20:00:03.000000Z", "2026-10-14T19:54:00.000000Z",
       "2026-10-14T19:59:45.000000Z", "2026-10-14T19:53:00.000000Z"},
      {33_068_217, "2026-10-14T20:00:15.000000Z", "2026-10-14T19:54:15.000000Z",
       "2026-10-14T20:00:00.000000Z", "2026-10-14T19:53:15.000000Z"}
    ]

    cases =
      for {round, published, freq_start, _, _} = row <- expected do
        t = FreqSchedule.freq_start_for_round(round)

        computed =
          {round, usec(Quicknet.pub_time(round)), usec(t), usec(FreqSchedule.fetch_deadline(t)),
           usec(FreqSchedule.latest_lock_at(t))}

        if computed != row, do: raise("schedule case differs: #{inspect({computed, row})}")
        {_, _, _, deadline, latest} = computed

        %{
          "drand_round" => round,
          "published_at" => published,
          "freq_start" => freq_start,
          "fetch_deadline" => deadline,
          "latest_lock_at" => latest
        }
      end

    %{
      "description" =>
        "#{@freq}: the draw schedule. For a quicknet round, freq_start (T) is the latest " <>
          "15 s grid point with T + 105 s + w_freq_secs + margin_secs <= published_at; " <>
          "fetch_deadline is T + 105 s + w_freq_secs; latest_lock_at is T - lock_gap_secs. " <>
          "Cases: 33068212 (T exactly at the bound), the round before (one step earlier), " <>
          "+3 s (same T) and +15 s (the next T).",
      "entropy_composition" => @freq,
      "readings" => FreqSchedule.readings(),
      "spacing_secs" => FreqSchedule.spacing_seconds(),
      "w_freq_secs" => FreqSchedule.fetch_window_seconds(),
      "margin_secs" => FreqSchedule.margin_seconds(),
      "lock_gap_secs" => FreqSchedule.lock_gap_seconds(),
      "stuck_run" => FreqGrammar.stuck_run(),
      "bounds_mhz" => [FreqGrammar.bounds().first, FreqGrammar.bounds().last],
      "cases" => cases
    }
  end

  # The Elexon FREQ rows for 19:53:45-19:56:00 UTC on 2026-10-14, as JSON
  # number text.
  @elexon %{
    "2026-10-14T19:53:45Z" => "50.023",
    "2026-10-14T19:54:00Z" => "50.012",
    "2026-10-14T19:54:15Z" => "50.018",
    "2026-10-14T19:54:30Z" => "50.012",
    "2026-10-14T19:54:45Z" => "49.983",
    "2026-10-14T19:55:00Z" => "49.98",
    "2026-10-14T19:55:15Z" => "49.953",
    "2026-10-14T19:55:30Z" => "49.912",
    "2026-10-14T19:55:45Z" => "49.883",
    "2026-10-14T19:56:00Z" => "49.887"
  }

  defp freq_value_file do
    valid = freq_valid()
    invalid = freq_invalid()
    readings_cases = freq_readings()
    from_rows = freq_from_rows()

    check_freq_values!(valid, invalid)
    check_freq_readings!(readings_cases)
    check_freq_from_rows!(from_rows)

    %{
      "description" =>
        "#{@freq}: the freq_value grammar (8 readings in whole mHz, 5 digits each, " <>
          "joined by ';', within bounds_mhz, no run of stuck_run identical readings) and " <>
          "how Elexon FREQ rows become one. readings: text is a reading's raw JSON number " <>
          "text. from_rows: rows are [measurementTime, raw JSON text of frequency], newest " <>
          "first as Elexon sends them. The rows for 2026-10-14 19:53:45-19:56:00 UTC are " <>
          "real Elexon readings; the other cases change them. valid and from_rows pin the " <>
          "stuck-run threshold from both sides (a run of stuck_run - 1 is valid).",
      "bounds_mhz" => [FreqGrammar.bounds().first, FreqGrammar.bounds().last],
      "stuck_run" => FreqGrammar.stuck_run(),
      "valid" => valid,
      "invalid" => for({value, reason} <- invalid, do: %{"value" => value, "reason" => reason}),
      "readings" =>
        for {text, want} <- readings_cases do
          if want == :error,
            do: %{"text" => text, "expected_error" => true},
            else: %{"text" => text, "expected_mhz" => want}
        end,
      "from_rows" =>
        for {start, rs, want} <- from_rows do
          case want do
            {:ok, value} -> %{"freq_start" => start, "rows" => rs, "expected_value" => value}
            :error -> %{"freq_start" => start, "rows" => rs, "expected_error" => true}
          end
        end
    }
  end

  defp freq_valid do
    [
      @freq_value,
      "50018;50012;49983;49980;49953;49912;49883;49887",
      "47000;52999;50000;50001;50000;50001;50000;50001",
      "50000;50000;50000;50000;50000;50011;50012;50013"
    ]
  end

  defp freq_invalid do
    readings = String.split(@freq_value, ";")
    with_first = fn r -> Enum.join([r | tl(readings)], ";") end
    stuck = fn n -> List.duplicate("50000", n) end

    [
      {Enum.join(Enum.take(readings, 7), ";"), "seven_readings"},
      {@freq_value <> ";49887", "nine_readings"},
      {with_first.("4998"), "four_digit_reading"},
      {with_first.("00000"), "zero_reading"},
      {with_first.("53000"), "above_bound"},
      {with_first.("46999"), "below_bound"},
      {Enum.join(stuck.(6) ++ ["50012", "50013"], ";"), "stuck_run_at_start"},
      {Enum.join(["50011", "50012"] ++ stuck.(6), ";"), "stuck_run_at_end"},
      {Enum.join(stuck.(8), ";"), "stuck_run_whole_window"},
      {" " <> @freq_value, "leading_space"},
      {@freq_value <> ";", "trailing_separator"},
      {String.replace(@freq_value, ";", ","), "comma_separator"},
      {with_first.("+5001"), "plus_sign"}
    ]
  end

  defp freq_readings do
    [
      {"50.018", 50_018},
      {"49.98", 49_980},
      {"50", 50_000},
      {"50.0", 50_000},
      {"47", 47_000},
      {"52.999", 52_999}
    ] ++
      for text <- ~w(0 0.000 46.999 53 49.9871 4.9987e1 5E1 -49.987) ++ [~s("49.983"), "null"],
          do: {text, :error}
  end

  defp freq_from_rows do
    t0 = "2026-10-14T19:54:00.000000Z"
    window = FreqSchedule.reading_times(~U[2026-10-14 19:54:00Z]) |> Enum.map(&stamp/1)
    real = rows(Enum.map(window, &{&1, @elexon[&1]}))
    reading = fn n -> Enum.at(window, n - 1) end

    replace = fn n, text ->
      rows(Enum.map(window, &{&1, if(&1 == reading.(n), do: text, else: @elexon[&1])}))
    end

    [
      {t0, real, {:ok, @freq_value}},
      {t0,
       rows(
         Enum.map(
           ["2026-10-14T19:53:45Z" | window] ++ ["2026-10-14T19:56:00Z"],
           &{&1, @elexon[&1]}
         )
       ), {:ok, @freq_value}},
      {t0, Enum.reject(real, fn [time, _] -> time == reading.(4) end), :error},
      {t0, (real ++ [[reading.(4), @elexon[reading.(4)]]]) |> sort_rows(), :error},
      {t0, replace.(3, "0"), :error},
      {t0, replace.(3, "4.9983e1"), :error},
      {t0, replace.(3, ~s("#{@elexon[reading.(3)]}")), :error},
      {t0, replace.(3, "null"), :error},
      {t0, rows(Enum.zip(window, List.duplicate("50", 6) ++ ["50.012", "50.013"])), :error},
      {t0, rows(Enum.zip(window, List.duplicate("50", 5) ++ ["50.011", "50.012", "50.013"])),
       {:ok, "50000;50000;50000;50000;50000;50011;50012;50013"}},
      {"2026-10-14T19:54:15.000000Z",
       rows(
         Enum.map(
           FreqSchedule.reading_times(~U[2026-10-14 19:54:15Z]) |> Enum.map(&stamp/1),
           &{&1, @elexon[&1]}
         )
       ), {:ok, "50018;50012;49983;49980;49953;49912;49883;49887"}}
    ]
  end

  defp check_freq_values!(valid, invalid) do
    for value <- valid, do: true = FreqGrammar.valid_value?(value)
    for {value, _} <- invalid, do: false = FreqGrammar.valid_value?(value)
  end

  defp check_freq_readings!(readings_cases) do
    for {text, want} <- readings_cases do
      {:ok, %{"f" => number}} = FreqGrammar.decode(~s({"f":#{text}}))
      got = FreqGrammar.reading_mhz(number)
      true = if want == :error, do: match?({:error, _}, got), else: got == {:ok, want}
    end
  end

  defp check_freq_from_rows!(from_rows) do
    for {start, rs, want} <- from_rows do
      {:ok, t, 0} = DateTime.from_iso8601(start)

      body =
        Enum.map_join(rs, ",", fn [time, text] ->
          ~s({"measurementTime":"#{time}","frequency":#{text}})
        end)

      {:ok, %{"data" => decoded}} = FreqGrammar.decode(~s({"data":[#{body}]}))
      got = FreqGrammar.window_from_rows(decoded, t)
      true = if want == :error, do: match?({:error, _}, got), else: got == want
    end
  end

  defp stamp(dt), do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")

  # [[measurementTime, text]], newest first.
  defp rows(pairs), do: pairs |> Enum.map(fn {t, v} -> [t, v] end) |> sort_rows()
  defp sort_rows(rows), do: Enum.sort_by(rows, &hd/1, :desc)

  # ── proof-bundle-v6-negative.json ─────────────────────────────────

  @oot ~w(weather_observation_window receipt_field_consistency seed_recomputation)

  defp negative_vector do
    cases =
      for {name, steps, build} <- negative_cases() do
        %{
          "name" => name,
          "bundle" => build.(),
          "expected_failing_steps" => Enum.sort(steps)
        }
      end

    %{
      "description" =>
        "Lock v6 / execution v5 proof bundles that must fail, for both tags " <>
          "(#{@landobs} and #{@freq}). Each case changes fields of a passing bundle " <>
          "(proof-bundle-v6*.json) and signs again with the keys in keys, so the " <>
          "signatures are valid over the bytes as written (cases that change only a " <>
          "wrapper key or the unsigned entropy are not re-signed); a changed lock also gets " <>
          "a recomputed, re-signed lock_receipt_hash. The seed, results and unsigned entropy are rebuilt " <>
          "from the changed execution receipt. expected_failing_steps is the exact set of " <>
          "verifier steps (snake_case) that fail; every other step passes or is skipped.",
      "keys" => keys(),
      "cases" => cases
    }
  end

  defp at(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    usec(dt)
  end

  # A case: change the lock and the execution receipt of a base (string-keyed
  # maps), then rebuild the bundle. `seed`: :landobs or :freq (see
  # `seed_for/2`), or :keep to keep the execution receipt's own seed.
  defp mutate(base, opts) do
    {_, lock_jcs, _, exec_jcs} = base(base)
    lock = Keyword.get(opts, :lock, & &1).(Jason.decode!(lock_jcs))
    exec = Keyword.get(opts, :exec, & &1).(Jason.decode!(exec_jcs))
    resign(lock, exec, Keyword.get(opts, :seed, rule(base)), opts)
  end

  defp resign(lock, exec, seed_rule, opts) do
    # Receipts are string-keyed, like the JSON they become.
    true = Enum.all?(Map.keys(lock) ++ Map.keys(exec), &is_binary/1)
    lock_jcs = Jcs.encode(lock)
    exec = Map.put(exec, "lock_receipt_hash", sha256_hex(lock_jcs))

    exec =
      case seed_rule do
        :keep ->
          exec

        rule ->
          {seed, winners} = seed_and_winners(seed_for(exec, rule))
          %{exec | "seed" => hex(seed), "results" => Enum.map(winners, & &1.entry_id)}
      end

    entropy = entropy_for(exec)
    entropy = Keyword.get(opts, :entropy, & &1).(entropy)
    bundle(lock_jcs, Jcs.encode(exec), Keyword.put(opts, :entropy, entropy))
  end

  defp put(key, value), do: &Map.put(&1, key, value)

  defp put(pairs) when is_list(pairs) do
    true = Enum.all?(pairs, fn {k, _} -> is_binary(k) end)
    &Map.merge(&1, Map.new(pairs))
  end

  defp negative_cases do
    wt = usec(Schedule.weather_time_for_round(@round))
    freq_tag_lock = fn -> elem(base(:freq_value), 1) |> Jason.decode!() end
    landobs_lock = fn -> elem(base(:a), 1) |> Jason.decode!() end

    landobs = [
      # Set A: the verifier's own landobs negatives, name for name.
      {"weather_time_not_whole_hour", ~w(bundle_shape weather_observation_window),
       fn ->
         mutate(:a,
           lock: put("weather_time", at("2026-10-14T19:30:00Z")),
           exec: put("weather_observation_time", at("2026-10-14T19:30:00Z"))
         )
       end},
      {"weather_time_not_calendar", ~w(bundle_shape weather_observation_window),
       fn ->
         mutate(:a,
           lock: put("weather_time", "2026-10-14T18:60:00.000000Z"),
           exec: put("weather_observation_time", "2026-10-14T18:60:00.000000Z")
         )
       end},
      {"weather_time_not_derived_from_round", ~w(weather_observation_window),
       fn ->
         mutate(:a,
           lock:
             put([
               {"weather_time", at("2026-10-14T18:00:00Z")},
               {"locked_at", at("2026-10-14T17:13:00Z")}
             ]),
           exec: put("weather_observation_time", at("2026-10-14T18:00:00Z"))
         )
       end},
      {"locked_at_after_latest_lock_at", ~w(weather_observation_window),
       fn -> mutate(:a, lock: put("locked_at", "2026-10-14T18:14:00.000001Z")) end},
      {"round_published_before_lock", ~w(weather_observation_window drand_bls_signature),
       fn -> mutate(:a, lock: put("locked_at", at("2026-10-14T20:00:01Z"))) end},
      {"lock_station_not_middle_wallop", ~w(bundle_shape receipt_field_consistency),
       fn -> mutate(:a, lock: put("weather_station", "wmo-03462")) end},
      {"exec_station_not_middle_wallop", ~w(bundle_shape receipt_field_consistency),
       fn -> mutate(:a, exec: put("weather_station", "wmo-03772")) end},
      {"exec_station_wittering", ~w(bundle_shape receipt_field_consistency),
       fn -> mutate(:a, exec: put("weather_station", "wmo-03462")) end},
      {"observation_time_not_weather_time", ~w(weather_observation_window),
       fn -> mutate(:a, exec: put("weather_observation_time", at("2026-10-14T20:00:00Z"))) end},
      {"partial_fallback_value_null_reason_null", @oot,
       fn -> mutate(:c, exec: put("weather_fallback_reason", nil)) end},
      {"partial_fallback_reason_set_value_set", @oot,
       fn -> mutate(:a, exec: put("weather_fallback_reason", @no_observation)) end},
      {"value_grammar_minus_zero", ~w(bundle_shape),
       fn -> mutate(:a, exec: put("weather_value", "-0;1012;67;3450")) end},
      {"value_grammar_leading_zero", ~w(bundle_shape),
       fn -> mutate(:a, exec: put("weather_value", "0123;1012;67;3450")) end},
      {"value_grammar_three_parts", ~w(bundle_shape),
       fn -> mutate(:a, exec: put("weather_value", "123;1012;67")) end},
      {"value_out_of_bounds", ~w(bundle_shape),
       fn -> mutate(:a, exec: put("weather_value", "601;1012;67;3450")) end},
      {"v5_reason_in_v6_exec",
       ~w(bundle_shape weather_observation_window receipt_field_consistency seed_recomputation),
       fn -> mutate(:c, exec: put("weather_fallback_reason", "unreachable")) end},
      {"wrong_entropy_composition",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn ->
         mutate(:a,
           lock: put("entropy_composition", @forecast),
           exec: put("entropy_composition", @forecast)
         )
       end},
      {"wrong_entropy_composition_exec",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn -> mutate(:a, exec: put("entropy_composition", @forecast)) end},
      {"lock_v6_with_exec_v4",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn -> mutate(:a, exec: &exec_v4/1) end},
      {"lock_v5_with_exec_v5",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn -> mutate(:a, lock: fn _ -> lock_v5() end) end},
      {"inline_key_on_lock_v6", ~w(bundle_shape), fn -> mutate(:a, inline_lock_key: true) end},
      {"inline_key_on_exec_v5", ~w(bundle_shape), fn -> mutate(:a, inline_exec_key: true) end},
      {"executed_before_round_published", ~w(drand_bls_signature),
       fn -> mutate(:a, exec: put("executed_at", at("2026-10-14T19:59:59Z"))) end},
      {"weather_with_freq_value", @oot,
       fn -> mutate(:a, exec: put("freq_value", @freq_value)) end},
      {"weather_with_freq_fallback_reason", @oot,
       fn -> mutate(:a, exec: put("freq_fallback_reason", @no_frequency)) end},
      {"freq_fallback_value_null_reason_null", @oot,
       fn -> mutate(:b, exec: put("freq_value", nil)) end},
      {"freq_value_without_weather_fallback_reason", @oot,
       fn -> mutate(:b, exec: put("weather_fallback_reason", nil)) end},
      {"freq_start_plus_15s", ~w(weather_observation_window),
       fn -> mutate(:a, lock: put("freq_start", at("2026-10-14T19:54:15Z"))) end},
      {"freq_start_plus_15s_on_freq_fallback", ~w(weather_observation_window),
       fn -> mutate(:b, lock: put("freq_start", at("2026-10-14T19:54:15Z"))) end},
      {"freq_start_off_grid", ~w(bundle_shape weather_observation_window),
       fn -> mutate(:a, lock: put("freq_start", at("2026-10-14T19:54:01Z"))) end},
      {"freq_start_null", ~w(bundle_shape lock_signature weather_observation_window),
       fn -> mutate(:a, lock: put("freq_start", nil)) end},
      {"freq_start_missing", ~w(bundle_shape lock_signature weather_observation_window),
       fn -> mutate(:a, lock: &Map.delete(&1, "freq_start")) end},
      {"freq_bundle_relabelled_landobs",
       ~w(bundle_shape lock_signature weather_observation_window receipt_field_consistency
          seed_recomputation),
       fn ->
         mutate(:freq_value,
           lock: put("entropy_composition", @landobs),
           exec: put("entropy_composition", @landobs),
           seed: :freq
         )
       end},
      # Set B: unknown and mismatched tags.
      {"unknown_v6_tag", ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn ->
         mutate(:a,
           lock: put("entropy_composition", "drand-quicknet+metoffice-landobs-v2"),
           exec: put("entropy_composition", "drand-quicknet+metoffice-landobs-v2")
         )
       end},
      {"entropy_composition_mismatch",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn -> mutate(:a, exec: put("entropy_composition", @freq)) end},
      # Every single-field step away from the three states.
      {"observation_time_without_weather_value", @oot,
       fn -> mutate(:a, exec: put("weather_value", nil)) end},
      {"freq_window_with_weather_value", @oot,
       fn -> mutate(:b, exec: put("weather_value", @weather_value)) end},
      {"freq_window_with_observation_time", @oot,
       fn -> mutate(:b, exec: put("weather_observation_time", wt)) end},
      {"fallback_with_weather_value", @oot,
       fn -> mutate(:c, exec: put("weather_value", @weather_value)) end},
      {"fallback_with_observation_time", @oot,
       fn -> mutate(:c, exec: put("weather_observation_time", wt)) end},
      {"fallback_executed_before_round_published", ~w(drand_bls_signature),
       fn -> mutate(:c, exec: put("executed_at", at("2026-10-14T19:59:59Z"))) end}
    ]

    first = fn value -> Enum.join([value | tl(String.split(@freq_value, ";"))], ";") end

    freq = [
      {"freq_start_not_derived_from_round", ~w(weather_observation_window),
       fn -> mutate(:freq_value, lock: put("freq_start", at("2026-10-14T19:53:45Z"))) end},
      {"freq_start_not_on_grid", ~w(bundle_shape weather_observation_window),
       fn -> mutate(:freq_value, lock: put("freq_start", at("2026-10-14T19:54:01Z"))) end},
      {"freq_locked_at_after_latest_lock_at", ~w(weather_observation_window),
       fn -> mutate(:freq_value, lock: put("locked_at", "2026-10-14T19:53:00.000001Z")) end},
      {"freq_round_published_before_lock", ~w(weather_observation_window drand_bls_signature),
       fn -> mutate(:freq_value, lock: put("locked_at", at("2026-10-14T20:00:01Z"))) end},
      {"freq_value_and_reason", ~w(weather_observation_window),
       fn -> mutate(:freq_value, exec: put("freq_fallback_reason", @no_frequency)) end},
      {"freq_value_null_reason_null", ~w(weather_observation_window),
       fn -> mutate(:freq_fallback, exec: put("freq_fallback_reason", nil)) end},
      {"freq_weather_reason", ~w(bundle_shape weather_observation_window),
       fn -> mutate(:freq_fallback, exec: put("freq_fallback_reason", @no_observation)) end},
      {"freq_value_stuck_run", ~w(bundle_shape),
       fn ->
         mutate(:freq_value,
           exec: put("freq_value", "50000;50000;50000;50000;50000;50000;50012;50013")
         )
       end},
      {"freq_value_zero_reading", ~w(bundle_shape),
       fn -> mutate(:freq_value, exec: put("freq_value", first.("00000"))) end},
      {"freq_value_out_of_bounds", ~w(bundle_shape),
       fn -> mutate(:freq_value, exec: put("freq_value", first.("53000"))) end},
      {"freq_value_four_digits", ~w(bundle_shape),
       fn -> mutate(:freq_value, exec: put("freq_value", first.("4998"))) end},
      {"weather_value_under_freq_tag", ~w(bundle_shape seed_recomputation),
       fn -> mutate(:freq_value, exec: put("weather_value", @weather_value)) end},
      {"weather_station_under_freq_tag", ~w(bundle_shape receipt_field_consistency),
       fn -> mutate(:freq_value, lock: put("weather_station", "wmo-03749")) end},
      {"freq_lock_with_landobs_exec",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn -> mutate(:a, lock: fn _ -> freq_tag_lock.() end, seed: :keep) end},
      {"landobs_lock_with_freq_exec",
       ~w(bundle_shape weather_observation_window receipt_field_consistency),
       fn -> mutate(:freq_value, lock: fn _ -> landobs_lock.() end, seed: :keep) end},
      {"unknown_freq_tag",
       ~w(bundle_shape lock_signature weather_observation_window receipt_field_consistency),
       fn ->
         mutate(:freq_value,
           lock: put("entropy_composition", "drand-quicknet+elexon-freq-v2"),
           exec: put("entropy_composition", "drand-quicknet+elexon-freq-v2")
         )
       end},
      {"freq_executed_before_round_published", ~w(drand_bls_signature),
       fn -> mutate(:freq_value, exec: put("executed_at", at("2026-10-14T19:59:59Z"))) end},
      {"freq_entropy_value_mismatch", ~w(drand_bls_signature),
       fn ->
         mutate(:freq_value,
           entropy: put("freq_value", String.replace_suffix(@freq_value, "49883", "49884"))
         )
       end}
    ]

    landobs ++ freq
  end

  # State (a)'s execution receipt as the execution 4 builder makes it: the
  # forecast tag, schema 4, no freq fields.
  defp exec_v4(exec) do
    {_, lock_jcs, input, _} = base(:a)

    input
    |> Map.drop([:entropy_composition, :freq_value, :freq_fallback_reason])
    |> Map.put(:lock_receipt_hash, sha256_hex(lock_jcs))
    |> Protocol.build_execution_receipt_payload()
    |> Jason.decode!()
    |> tap(fn v4 -> true = v4["seed"] == exec["seed"] end)
  end

  # The state (a) lock as the lock 5 builder makes it: the forecast tag,
  # schema 5, no freq_start.
  defp lock_v5 do
    lock_input(@landobs)
    |> Map.drop([:entropy_composition, :freq_start])
    |> Protocol.build_receipt_payload()
    |> Jason.decode!()
  end

  # ── Output ────────────────────────────────────────────────────────

  defp write(file, data), do: write_raw(file, encode(data))

  defp write_raw(file, text) do
    path = Path.join(@dir, file)
    File.write!(path, text)
    IO.puts("Wrote #{path}")
  end

  # Pretty JSON, keys sorted, trailing newline.
  defp encode(data), do: data |> sorted() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")

  defp sorted(map) when is_map(map),
    do:
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> {k, sorted(v)} end)
      |> Jason.OrderedObject.new()

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other

  defp usec(%DateTime{} = dt), do: WallopCore.Time.to_rfc3339_usec(dt)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> hex()
end

WallopCore.VectorsV6.run()
