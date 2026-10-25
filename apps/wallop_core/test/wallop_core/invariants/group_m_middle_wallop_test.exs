defmodule WallopCore.Invariants.GroupMMiddleWallopTest do
  @moduledoc """
  Group M: observation-weather draws use Middle Wallop only. When its
  reading misses the fetch deadline they use the grid-frequency window of
  the same drand round, and when that is missing too, drand alone
  (INV-M1 to INV-M9). Each invariant carries `@tag :pending_task_M<n>`
  until task n of its plan delivers it.
  """
  use WallopCore.InvariantCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  @moduletag :invariant

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.FrequencyWindowWorker
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Frequency.Windows
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Repo
  alias WallopCore.Weather.{Schedule, Stations}

  @wt ~N[2026-10-14 19:00:00.000000]
  @hours [
    ~U[2026-10-25 00:00:00Z],
    ~U[2026-10-25 01:00:00Z],
    ~U[2026-03-29 00:00:00Z],
    ~U[2026-12-31 23:00:00Z]
  ]
  @genesis 1_692_803_367
  @no_obs "no_observation_by_deadline"
  @no_freq "no_frequency_by_deadline"
  @value "141;1025;85;2432"
  @freq "50012;50018;50012;49983;49980;49953;49912;49883"

  defp sql_one(sql, params \\ []) do
    %{rows: [[v]]} = Repo.query!(sql, params)
    v
  end

  defp constraint_def(name),
    do: sql_one("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [name])

  # A weather-tag draw in pending_entropy whose round published `ago`
  # seconds ago, so F + 1 min and F_freq + M have both passed.
  defp pending_past(key, ago \\ 10) do
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -ago))
    wt = Schedule.weather_time_for_round(round)
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    draw
  end

  @complete """
  UPDATE draws SET status = 'completed', executed_at = $2, weather_value = $3,
    weather_observation_time = $4, weather_fallback_reason = $5,
    freq_value = $6, freq_fallback_reason = $7
  WHERE id = $1
  """

  # nil when the completion is accepted (rolled back either way), else the refusal.
  defp complete(draw, {value, observed, reason, freq, freq_reason}) do
    try_sql(@complete, [
      dump(draw.id),
      NaiveDateTime.utc_now(),
      value,
      observed && DateTime.to_naive(observed),
      reason,
      freq,
      freq_reason
    ])
  end

  test "INV-M1 the observation tag names one station, Middle Wallop, in Elixir and SQL" do
    assert Stations.ids() == ["wmo-03749"]
    assert sql_one("SELECT wallop_landobs_primary_station()") == "wmo-03749"

    assert sql_one(
             "SELECT count(*) FROM pg_proc WHERE proname IN " <>
               "('wallop_landobs_stations', 'wallop_landobs_backup_station')"
           ) == 0

    assert constraint_def("weather_observations_station") =~ "wallop_landobs_primary_station()"

    for offset_s <- [0, 1200, 1201, 1800] do
      now = NaiveDateTime.add(@wt, offset_s)

      refute sql_one("SELECT wallop_landobs_observation_allowed('wmo-03462', $1, $2)", [@wt, now]),
             "Wittering at +#{offset_s}s"
    end
  end

  test "INV-M2 Middle Wallop's reading may be stored anywhere in [wt, F] and nowhere else" do
    w_us = Schedule.fetch_window_seconds() * 1_000_000
    old_cutover = w_us - 600_000_000

    for {offset, expected} <- [
          {-1, false},
          {0, true},
          {old_cutover, true},
          {old_cutover + 1, true},
          {w_us, true},
          {w_us + 1, false}
        ] do
      now = NaiveDateTime.add(@wt, offset, :microsecond)

      assert sql_one("SELECT wallop_landobs_observation_allowed($1, $2, $3)", [
               "wmo-03749",
               @wt,
               now
             ]) == expected,
             "at #{offset} µs"
    end
  end

  @tag :pending_task_M4
  test "INV-M3 a weather-tag lock carries freq_start, the window start its round implies" do
    {_op, key} = create_v6_operator()
    s = in_time_schedule()
    t = FreqSchedule.freq_start_for_round(s.round)
    d = open_draw_with_entries(key)

    assert raw_lock(d, s.weather_time, s.round, freq_start: nil) ==
             "freq_start must follow from drand_round"

    assert raw_lock(d, s.weather_time, s.round, freq_start: DateTime.add(t, 15)) ==
             "freq_start must follow from drand_round"

    assert raw_lock(d, s.weather_time, s.round) == nil
    assert LandObs.lock_keys() == Freq.lock_keys()
    assert length(LandObs.lock_keys()) == 20
    assert sql_one("SELECT wallop_v6_lock_keys()") == LandObs.lock_keys()
  end

  @tag :pending_task_M5
  test "INV-M4 T's window is stored when only weather-tag draws wait on T" do
    {_op, key} = create_v6_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 60))
    t = FreqSchedule.freq_start_for_round(round)

    draw =
      put_v6_awaiting!(open_draw_with_entries(key), Schedule.weather_time_for_round(round), round)

    assert DateTime.compare(draw.freq_start, t) == :eq
    assert {:ok, _} = Windows.store(t, @freq, elexon_body(t, @freq))
    assert %{value: @freq} = Windows.for_start(t)
  end

  @tag :pending_task_M5
  test "INV-M5 a weather-tag draw completes in exactly one of the three states" do
    {_op, key} = create_v6_operator()
    stored_only = "v6 draw must complete with its stored observation"
    window_only = "v6 draw must complete with its stored frequency window"
    fallback_only = "v6 draw may fall back only after the fetch deadline with nothing stored"

    # Nothing stored: only (c).
    d = pending_past(key)
    assert complete(d, {nil, nil, @no_obs, nil, @no_freq}) == nil
    assert complete(d, {nil, nil, @no_obs, @freq, nil}) == fallback_only
    assert complete(d, {nil, nil, @no_obs, nil, nil}) == fallback_only
    assert complete(d, {nil, nil, nil, nil, @no_freq}) == fallback_only

    # A window stored for T: only (b), with exactly that window.
    d = pending_past(key, 40)
    put_frequency_window!(d.freq_start, @freq)
    assert complete(d, {nil, nil, @no_obs, @freq, nil}) == nil
    assert complete(d, {nil, nil, @no_obs, nil, @no_freq}) == window_only
    assert complete(d, {nil, nil, @no_obs, @freq, @no_freq}) == window_only

    # The hour's reading stored (and a window too): only (a), freq fields null.
    d = pending_past(key, 70)
    put_frequency_window!(d.freq_start, @freq)
    put_observation!("wmo-03749", d.weather_time, @value)
    assert complete(d, {@value, d.weather_time, nil, nil, nil}) == nil
    assert complete(d, {@value, d.weather_time, nil, @freq, nil}) == stored_only
    assert complete(d, {@value, d.weather_time, nil, nil, @no_freq}) == stored_only
    assert complete(d, {nil, nil, @no_obs, @freq, nil}) == stored_only
  end

  @tag :pending_task_M5
  test "INV-M6 (b) and (c) need now > F + 1 min; (c) also needs now > F_freq + M" do
    {_op, key} = create_v6_operator()
    fallback_only = "v6 draw may fall back only after the fetch deadline with nothing stored"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # F = now: F + 1 min is still ahead.
    d = pending_past(key)
    shift!(d, weather_time: DateTime.add(now, -Schedule.fetch_window_seconds()))
    assert complete(d, {nil, nil, @no_obs, nil, @no_freq}) == fallback_only

    # F long past, F_freq + M just ahead of now (T on the 15 s grid, as the
    # window table's CHECK requires): (c) refused, (b) with a stored window accepted.
    d = pending_past(key, 40)
    now_u = DateTime.to_unix(now)

    settle =
      FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() +
        FreqSchedule.margin_seconds()

    t = DateTime.from_unix!(now_u + rem(15 - rem(now_u, 15), 15) + 15 - settle)
    shift!(d, freq_start: t)
    assert complete(d, {nil, nil, @no_obs, nil, @no_freq}) == fallback_only
    put_frequency_window!(t, @freq)
    assert complete(d, {nil, nil, @no_obs, @freq, nil}) == nil
  end

  # Moves a stored column with every trigger off (the draws guard freezes
  # them once the draw has left open), so a clock condition can be placed.
  defp shift!(draw, [{column, %DateTime{} = value}])
       when column in [:weather_time, :freq_start] do
    Repo.query!("SET session_replication_role = replica")

    try do
      Repo.query!("UPDATE draws SET #{column} = $2 WHERE id = $1", [
        dump(draw.id),
        DateTime.to_naive(value)
      ])
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  test "INV-M7 both stores settle before drand for every draw second of the hour" do
    for wt <- @hours, d <- 0..3597//3 do
      wt_u = DateTime.to_unix(wt)
      pub = wt_u + 1860 + d
      {:ok, s} = Schedule.schedule(DateTime.from_unix!(pub))
      t = DateTime.to_unix(s.freq_start)
      f = DateTime.to_unix(s.fetch_deadline)
      f_freq = DateTime.to_unix(FreqSchedule.fetch_deadline(s.freq_start))

      assert DateTime.to_unix(s.weather_time) == wt_u, "d=#{d}"
      assert t == wt_u + 1500 + d - rem(d, 15), "d=#{d}"
      assert f_freq - f >= 45, "d=#{d}"
      assert f + 60 <= pub, "d=#{d}"
      assert f_freq + FreqSchedule.margin_seconds() <= pub, "d=#{d}"
      assert DateTime.to_unix(s.latest_lock_at) <= t - 60, "d=#{d}"
      assert t >= wt_u + 25 * 60, "d=#{d}"
    end

    # The same facts from the SQL functions, under a non-UTC session.
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")
    hours = Enum.map(@hours, &DateTime.to_naive/1)

    %{rows: [[checked, broken]]} =
      Repo.query!(
        """
        SELECT count(*), count(*) FILTER (WHERE NOT ok) FROM (
          SELECT wallop_landobs_weather_time(r) = wt
             AND wallop_quicknet_pub_time(r) = pub
             AND wallop_freq_fetch_deadline(wallop_freq_start(r))
                 >= wt + wallop_landobs_fetch_window() + interval '45 seconds'
             AND wt + wallop_landobs_fetch_window() + interval '60 seconds' <= pub
             AND wallop_freq_fetch_deadline(wallop_freq_start(r)) + wallop_freq_margin() <= pub
             AND wt - wallop_landobs_lock_offset() <= wallop_freq_start(r) - wallop_freq_lock_gap()
             AND wallop_freq_start(r) >= wt + interval '25 minutes' AS ok
          FROM (
            SELECT wt, wt + make_interval(secs => 1860 + d) AS pub,
                   (EXTRACT(EPOCH FROM wt)::bigint + 1860 + d - #{@genesis}) / 3 + 1 AS r
            FROM unnest($1::timestamp[]) wt, generate_series(0, 3597, 3) d
          ) s
        ) x
        """,
        [hours]
      )

    assert {checked, broken} == {1200 * length(@hours), 0}
  end

  @tag :pending_task_M6
  test "INV-M8 a weather-tag lock enqueues T's window job in the lock transaction, once per T" do
    ensure_infrastructure_key()
    {_op, key} = create_v6_operator()
    s = in_time_schedule()
    t = FreqSchedule.freq_start_for_round(s.round)
    arg = %{freq_start: FrequencyWindowWorker.start_arg(t)}

    for _ <- 1..2 do
      {:ok, _} =
        key
        |> open_draw_with_entries()
        |> Ash.Changeset.for_update(:lock, %{draw_at: s.draw_at}, actor: key)
        |> Ash.update()
    end

    assert length(all_enqueued(worker: FrequencyWindowWorker, args: arg)) == 1
    assert Windows.waiting_tags() == [Freq.tag(), LandObs.tag()]
  end

  @tag :pending_task_M5
  test "INV-M9 a weather-tag draw still can't fail from the weather F, the earlier deadline" do
    {_op, key} = create_v6_operator()
    d = pending_past(key)

    assert sql_one(
             "SELECT wallop_v6_fetch_deadline($1, $2, $3)",
             [LandObs.tag(), DateTime.to_naive(d.weather_time), DateTime.to_naive(d.freq_start)]
           ) ==
             NaiveDateTime.add(DateTime.to_naive(d.weather_time), Schedule.fetch_window_seconds())

    assert try_sql("UPDATE draws SET status = 'failed' WHERE id = $1", [dump(d.id)]) ==
             "a v6 draw can't fail once its fetch deadline has passed"
  end
end
