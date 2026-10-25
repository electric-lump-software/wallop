defmodule WallopCore.ScheduleBoundariesTest do
  @moduledoc """
  `spec/vectors/schedule-boundaries-v1.json`: v6 draw schedules for every
  whole minute from 22:00 to 02:59 UTC across both UK clock changes, a
  month end, a year end, a February without a leap day and both sides of
  29 February 2028, plus off-minute quicknet grid points. The expected
  values come from a reference written independently of core.

  `WallopCore.Weather.Schedule` and `WallopCore.Frequency.Schedule` must
  match every case. The SQL timing functions the v6 guards use must match
  them too; this checks every case, which includes every case whose times
  straddle a UTC date, with the session time zone set to Europe/London.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Weather.Schedule, as: WeatherSchedule

  @path Path.expand("../../../../spec/vectors/schedule-boundaries-v1.json", __DIR__)
  @external_resource @path
  @vector @path |> File.read!() |> Jason.decode!()

  @windows ~w(bst_ends bst_starts month_end year_end no_leap_day leap_day_eve leap_day)

  def vector, do: @vector

  def landobs_cases,
    do: @vector["landobs"] ++ @vector["landobs_grid_seconds"] ++ [@vector["landobs_w30_not_w40"]]

  def freq_cases, do: @vector["freq"] ++ @vector["freq_grid_seconds"]

  def time(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    DateTime.truncate(dt, :second)
  end

  # Equal to the second, and a whole second, whatever the precision marker.
  defp assert_time(%DateTime{} = got, iso, label) do
    assert DateTime.to_unix(got, :microsecond) == DateTime.to_unix(time(iso), :microsecond),
           "#{label}: got #{DateTime.to_iso8601(got)}, expected #{iso}"
  end

  describe "the vector file" do
    test "covers every whole minute of every window, 22:00 to 02:59" do
      for key <- ~w(landobs freq) do
        by_window = Enum.group_by(@vector[key], & &1["window"])
        assert Map.keys(by_window) |> Enum.sort() == Enum.sort(@windows)

        for {window, cases} <- by_window do
          times = Enum.map(cases, &DateTime.to_unix(time(&1["draw_at"])))
          assert length(times) == 300, "#{key} #{window}"
          assert times == Enum.to_list(hd(times)..(hd(times) + 299 * 60)//60)
          assert %{hour: 22, minute: 0} = time(hd(cases)["draw_at"])
        end
      end
    end

    test "the W = 30 case would have another weather_time under W = 40" do
      c = @vector["landobs_w30_not_w40"]
      draw_at = DateTime.to_unix(time(c["draw_at"]))
      w40 = div(draw_at - 40 * 60 - 60, 3600) * 3600
      refute w40 == DateTime.to_unix(time(c["weather_time"]))
    end
  end

  describe "WallopCore.Weather.Schedule" do
    test "matches every observation weather case" do
      for c <- landobs_cases() do
        label = "landobs #{c["draw_at"]}"
        assert {:ok, s} = WeatherSchedule.schedule(time(c["draw_at"])), label
        assert s.round == c["round"], label
        assert_time(s.draw_at, c["draw_at"], label <> " draw_at")
        assert_time(s.expected_result_at, c["draw_at"], label <> " expected_result_at")
        assert_time(s.weather_time, c["weather_time"], label <> " weather_time")
        assert_time(s.fetch_deadline, c["fetch_deadline"], label <> " fetch_deadline")
        assert_time(s.latest_lock_at, c["latest_lock_at"], label <> " latest_lock_at")

        assert_time(
          WeatherSchedule.weather_time_for_round(c["round"]),
          c["weather_time"],
          label <> " weather_time_for_round"
        )
      end
    end
  end

  describe "WallopCore.Frequency.Schedule" do
    test "matches every grid-frequency case" do
      for c <- freq_cases() do
        label = "freq #{c["draw_at"]}"
        assert {:ok, s} = FreqSchedule.schedule(time(c["draw_at"])), label
        assert s.round == c["round"], label
        assert_time(s.draw_at, c["draw_at"], label <> " draw_at")
        assert_time(s.expected_result_at, c["draw_at"], label <> " expected_result_at")
        assert_time(s.freq_start, c["freq_start"], label <> " freq_start")
        assert_time(s.fetch_deadline, c["fetch_deadline"], label <> " fetch_deadline")
        assert_time(s.latest_lock_at, c["latest_lock_at"], label <> " latest_lock_at")

        assert_time(
          FreqSchedule.freq_start_for_round(c["round"]),
          c["freq_start"],
          label <> " freq_start_for_round"
        )
      end
    end
  end
end

defmodule WallopCore.ScheduleBoundariesSqlTest do
  @moduledoc """
  The SQL side of `spec/vectors/schedule-boundaries-v1.json`; see
  `WallopCore.ScheduleBoundariesTest`.

  For each case, in a Europe/London session:

    * `wallop_quicknet_pub_time(round)` is `draw_at`;
    * landobs: `wallop_landobs_weather_time(round)` is `weather_time`;
      `wallop_v6_fetch_deadline` is the fetch deadline;
      `wallop_landobs_lock_allowed` holds at `latest_lock_at` and not 1 µs
      later; `wallop_landobs_observation_allowed` takes Middle Wallop
      from `weather_time` up to the fetch deadline and not 1 µs either
      side, and no other station;
    * freq: `wallop_freq_start(round)` is `freq_start`;
      `wallop_freq_fetch_deadline` and `wallop_v6_fetch_deadline` are the
      fetch deadline; `wallop_freq_store_allowed` holds at the deadline
      and not 1 µs later; `wallop_freq_lock_allowed` holds at
      `latest_lock_at` and not 1 µs later.
  """
  use WallopCore.DataCase, async: false

  import WallopCore.ScheduleBoundariesTest, only: [landobs_cases: 0, freq_cases: 0, time: 1]

  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Weather.Stations

  setup do
    # The windows include both UK clock changes: a session in UK time must
    # still give the UTC answers.
    Repo.query!("SET LOCAL TIME ZONE 'Europe/London'")
    :ok
  end

  defp naive(iso), do: iso |> time() |> DateTime.to_naive()

  # A case straddles a date when any of its times is on another UTC date
  # than its draw_at.
  defp straddles?(c, keys) do
    day = time(c["draw_at"]) |> DateTime.to_date()
    Enum.any?(keys, &(DateTime.to_date(time(c[&1])) != day))
  end

  test "the SQL checks cover at least 200 cases, among them every case that straddles a date" do
    landobs_keys = ~w(weather_time fetch_deadline latest_lock_at)
    freq_keys = ~w(freq_start fetch_deadline latest_lock_at)
    straddling = Enum.count(landobs_cases(), &straddles?(&1, landobs_keys))
    straddling_freq = Enum.count(freq_cases(), &straddles?(&1, freq_keys))

    # Every case is checked below, so every straddling case is too.
    assert length(landobs_cases()) + length(freq_cases()) >= 200
    assert straddling > 0 and straddling_freq > 0
  end

  test "the observation weather SQL functions match every case" do
    cases = landobs_cases()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.r,
               wallop_quicknet_pub_time(c.r) = c.draw_at,
               wallop_landobs_weather_time(c.r) = c.wt,
               wallop_v6_fetch_deadline($5, wallop_landobs_weather_time(c.r), NULL) = c.f,
               wallop_landobs_lock_allowed(c.lock, wallop_landobs_weather_time(c.r)),
               wallop_landobs_lock_allowed(c.lock + interval '1 microsecond',
                                           wallop_landobs_weather_time(c.r)),
               wallop_landobs_observation_allowed($6, c.wt, c.wt - interval '1 microsecond'),
               wallop_landobs_observation_allowed($6, c.wt, c.wt),
               wallop_landobs_observation_allowed($6, c.wt, c.f),
               wallop_landobs_observation_allowed($6, c.wt, c.f + interval '1 microsecond'),
               wallop_landobs_observation_allowed($8, c.wt, c.wt),
               wallop_landobs_observation_allowed($8, c.wt, c.f)
        FROM unnest($1::bigint[], $2::timestamp[], $3::timestamp[], $4::timestamp[],
                    $7::timestamp[]) AS c(r, draw_at, wt, f, lock)
        """,
        [
          Enum.map(cases, & &1["round"]),
          Enum.map(cases, &naive(&1["draw_at"])),
          Enum.map(cases, &naive(&1["weather_time"])),
          Enum.map(cases, &naive(&1["fetch_deadline"])),
          LandObs.tag(),
          Stations.primary().id,
          Enum.map(cases, &naive(&1["latest_lock_at"])),
          "wmo-03462"
        ]
      )

    assert length(rows) == length(cases)

    expected = [true, true, true, true, false, false, true, true, false, false, false]

    for [round | got] <- rows do
      assert got == expected, "landobs round #{round}"
    end
  end

  test "the grid-frequency SQL functions match every case" do
    cases = freq_cases()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.r,
               wallop_quicknet_pub_time(c.r) = c.draw_at,
               wallop_freq_start(c.r) = c.t,
               wallop_freq_fetch_deadline(wallop_freq_start(c.r)) = c.f,
               wallop_v6_fetch_deadline($6, NULL, wallop_freq_start(c.r)) = c.f,
               wallop_freq_store_allowed(c.t, c.f),
               wallop_freq_store_allowed(c.t, c.f + interval '1 microsecond'),
               wallop_freq_lock_allowed(c.lock, wallop_freq_start(c.r)),
               wallop_freq_lock_allowed(c.lock + interval '1 microsecond', wallop_freq_start(c.r))
        FROM unnest($1::bigint[], $2::timestamp[], $3::timestamp[], $4::timestamp[],
                    $5::timestamp[]) AS c(r, draw_at, t, f, lock)
        """,
        [
          Enum.map(cases, & &1["round"]),
          Enum.map(cases, &naive(&1["draw_at"])),
          Enum.map(cases, &naive(&1["freq_start"])),
          Enum.map(cases, &naive(&1["fetch_deadline"])),
          Enum.map(cases, &naive(&1["latest_lock_at"])),
          Freq.tag()
        ]
      )

    assert length(rows) == length(cases)

    expected = [true, true, true, true, true, false, true, false]

    for [round | got] <- rows do
      assert got == expected, "freq round #{round}"
    end
  end
end
