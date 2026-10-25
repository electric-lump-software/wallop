defmodule WallopCore.Weather.SqlSchedulePropertyTest do
  @moduledoc """
  The SQL timing functions and constants the v6 guards use must equal the
  Elixir ones exactly, in any session time zone.
  """
  use WallopCore.DataCase, async: false
  use ExUnitProperties

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Weather.{Schedule, Stations}

  setup do
    # Any session time zone must give the same answers as UTC.
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")
    :ok
  end

  defp sql_one(sql, params \\ []) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end

  defp utc(naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp sql_weather_time(round),
    do: utc(sql_one("SELECT wallop_landobs_weather_time($1)", [round]))

  defp sql_lock_allowed?(%DateTime{} = at, %DateTime{} = wt),
    do:
      sql_one("SELECT wallop_landobs_lock_allowed($1, $2)", [
        DateTime.to_naive(at),
        DateTime.to_naive(wt)
      ])

  property "SQL pub time and weather_time match Schedule" do
    check all(round <- integer(1..90_000_000), max_runs: 300) do
      %{rows: [[pub, wt]]} =
        Repo.query!("SELECT wallop_quicknet_pub_time($1), wallop_landobs_weather_time($1)", [
          round
        ])

      assert utc(pub) == Schedule.pub_time(round)
      assert utc(wt) == Schedule.weather_time_for_round(round)
    end
  end

  property "SQL lock_allowed matches Schedule.lock_allowed?" do
    check all(
            round <- integer(1..90_000_000),
            offset_us <- integer(-7_200_000_000..7_200_000_000),
            max_runs: 300
          ) do
      wt = Schedule.weather_time_for_round(round)
      at = DateTime.add(wt, offset_us, :microsecond)
      assert sql_lock_allowed?(at, wt) == Schedule.lock_allowed?(at, wt)
    end
  end

  property "wallop_parse_rfc3339_usec reads the receipts' canonical time strings exactly" do
    check all(us <- integer(0..4_102_444_800_000_000), max_runs: 300) do
      dt = DateTime.from_unix!(us, :microsecond)

      assert utc(
               sql_one("SELECT wallop_parse_rfc3339_usec($1)", [
                 WallopCore.Time.to_rfc3339_usec(dt)
               ])
             ) ==
               dt
    end
  end

  test "wallop_parse_rfc3339_usec refuses anything but the canonical form" do
    for bad <- [
          "2026-10-15T12:00:00Z",
          "2026-10-15T12:00:00.000000+00:00",
          "2026-10-15T12:00:00.000000+05:30",
          "2026-10-15T13:00:00.000000+01:00",
          "2026-10-15T12:00:00.000000-00:00",
          "2026-10-15T11:00:00.000000-01:00",
          "2026-10-15 12:00:00.000000Z",
          "2026-10-15T12:00:00.000000",
          "2026-10-15T24:00:00.000000Z",
          "2026-10-15T23:59:60.000000Z",
          "2026-02-30T12:00:00.000000Z",
          "2026-13-01T12:00:00.000000Z",
          "2026-10-15T12:60:00.000000Z"
        ] do
      assert_raise Postgrex.Error, ~r/not a canonical UTC timestamp/, fn ->
        Repo.transaction(fn -> Repo.query!("SELECT wallop_parse_rfc3339_usec($1)", [bad]) end)
      end
    end
  end

  test "pub time is exact at the far end of the property range and beyond" do
    for round <- [1, 90_000_000, 1_000_000_000] do
      assert utc(sql_one("SELECT wallop_quicknet_pub_time($1)", [round])) ==
               Schedule.pub_time(round)
    end
  end

  describe "pinned boundaries" do
    @h ~U[2026-10-15 12:00:00.000000Z]

    test "pub == h + W + 60s gives weather_time h" do
      pub = DateTime.add(@h, Schedule.fetch_window_seconds() + 60, :second)
      {:ok, round} = Quicknet.round_at(pub)

      assert Schedule.weather_time_for_round(round) == @h
      assert sql_weather_time(round) == @h
    end

    test "one 3s grid step earlier gives the hour before" do
      pub = DateTime.add(@h, Schedule.fetch_window_seconds() + 60 - Quicknet.period(), :second)
      {:ok, round} = Quicknet.round_at(pub)
      hour_before = DateTime.add(@h, -3600, :second)

      assert Schedule.weather_time_for_round(round) == hour_before
      assert sql_weather_time(round) == hour_before
    end

    test "a lock exactly at weather_time - 46m is in time; one microsecond later is not" do
      last = DateTime.add(@h, -Schedule.lock_offset_seconds(), :second)
      late = DateTime.add(last, 1, :microsecond)

      assert Schedule.lock_allowed?(last, @h)
      assert sql_lock_allowed?(last, @h)
      refute Schedule.lock_allowed?(late, @h)
      refute sql_lock_allowed?(late, @h)
    end
  end

  describe "SQL constants equal the Elixir ones" do
    test "the fetch window equals W" do
      assert sql_one("SELECT EXTRACT(EPOCH FROM wallop_landobs_fetch_window())::int") ==
               Schedule.fetch_window_seconds()
    end

    test "the lock offset equals Schedule's" do
      assert sql_one("SELECT EXTRACT(EPOCH FROM wallop_landobs_lock_offset())::int") ==
               Schedule.lock_offset_seconds()
    end

    test "the quicknet chain hash" do
      assert sql_one("SELECT wallop_quicknet_chain_hash()") == Quicknet.chain_hash()
    end

    test "the tag and its fallback reason" do
      assert sql_one("SELECT wallop_landobs_tag()") == LandObs.tag()
      assert sql_one("SELECT wallop_landobs_fallback_reason()") == LandObs.fallback_reason()
    end

    test "the station literals" do
      assert sql_one("SELECT wallop_landobs_primary_station()") == Stations.primary().id
    end
  end
end
