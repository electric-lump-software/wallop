defmodule WallopCore.Weather.ObservationWindowTest do
  @moduledoc """
  The SQL predicates the observation store's trigger and CHECKs use, pinned
  against exact instants and against their Elixir counterparts. The DB clock
  can't be set from a test, so the window boundaries are pinned here, on the
  function the trigger calls.
  """
  use WallopCore.DataCase, async: false
  use ExUnitProperties

  alias WallopCore.Repo
  alias WallopCore.Weather.{LandObsGrammar, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @wt ~N[2026-10-14 19:00:00.000000]

  defp sql_one(sql, params \\ []) do
    %{rows: [[v]]} = Repo.query!(sql, params)
    v
  end

  defp allowed?(station, offset_us) do
    now = NaiveDateTime.add(@wt, offset_us, :microsecond)
    sql_one("SELECT wallop_landobs_observation_allowed($1, $2, $3)", [station, @wt, now])
  end

  test "exact boundaries, in a non-UTC session" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")
    cutover = (@w - 10 * 60) * 1_000_000
    deadline = @w * 1_000_000

    #   instant              primary  backup
    for {offset, primary, backup} <- [
          {-1, false, false},
          {0, true, false},
          {cutover, true, false},
          {cutover + 1, false, true},
          {deadline, false, true},
          {deadline + 1, false, false}
        ] do
      assert allowed?(Stations.primary().id, offset) == primary, "primary at #{offset}us"
      assert allowed?(Stations.backup().id, offset) == backup, "backup at #{offset}us"
    end

    refute allowed?("wmo-99999", 0)
  end

  test "the boundaries are Schedule's backup cutover and fetch deadline" do
    wt = DateTime.from_naive!(@wt, "Etc/UTC")
    assert DateTime.diff(Schedule.backup_cutover(wt), wt) == @w - 10 * 60
    assert DateTime.diff(Schedule.fetch_deadline(wt), wt) == @w
  end

  describe "the SQL station literals equal Stations" do
    test "the backup station and the full list" do
      assert sql_one("SELECT wallop_landobs_backup_station()") == Stations.backup().id
      assert sql_one("SELECT wallop_landobs_primary_station()") == Stations.primary().id
      assert sql_one("SELECT wallop_landobs_stations()") == Stations.ids()

      assert sql_one(
               "SELECT ARRAY[wallop_landobs_primary_station(), wallop_landobs_backup_station()]"
             ) ==
               Stations.ids()
    end

    test "the table's station CHECK accepts exactly Stations.ids()" do
      assert constraint_def("weather_observations_station") =~ "wallop_landobs_stations()"

      for id <- Stations.ids() do
        assert sql_one("SELECT $1 = ANY (wallop_landobs_stations())", [id]), id
      end

      refute sql_one("SELECT $1 = ANY (wallop_landobs_stations())", ["wmo-99999"])
    end

    test "every station in Stations has a window, and nothing else does" do
      in_window = for id <- Stations.ids(), do: allowed?(id, 0) or allowed?(id, @w * 1_000_000)
      assert Enum.all?(in_window)
    end
  end

  describe "the value CHECK is LandObsGrammar.valid_value?/1" do
    test "the table's CHECK calls wallop_landobs_valid_value" do
      assert constraint_def("weather_observations_value_grammar") =~
               "wallop_landobs_valid_value(value)"
    end

    test "pinned cases" do
      for {value, ok} <- [
            {"141;1025;85;2432", true},
            {"0;850;0;0", true},
            {"-900;1100;100;10000", true},
            {"600;850;0;0", true},
            {"601;1025;85;2432", false},
            {"-901;1025;85;2432", false},
            {"141;849;85;2432", false},
            {"141;1101;85;2432", false},
            {"141;1025;101;2432", false},
            {"141;1025;85;10001", false},
            {"-0;1025;85;2432", false},
            {"01;1025;85;2432", false},
            {"141;1025;85", false},
            {"141;1025;85;2432;", false},
            {"141;1025;85;2432\n", false},
            {" 141;1025;85;2432", false},
            {"102500", false},
            {"", false}
          ] do
        assert sql_valid?(value) == ok, inspect(value)
        assert LandObsGrammar.valid_value?(value) == ok, inspect(value)
      end
    end

    property "SQL and Elixir agree on generated values" do
      part =
        one_of([
          integer(-1_200..12_000),
          map(integer(0..999), &"0#{&1}"),
          constant("-0"),
          map(integer(1..99), &"+#{&1}"),
          map(integer(0..99), &"#{&1}.0")
        ])

      check all(
              parts <- list_of(part, min_length: 3, max_length: 5),
              sep <- member_of([";", ";", ";", ",", "; "]),
              max_runs: 500
            ) do
        value = Enum.map_join(parts, sep, &to_string/1)
        assert sql_valid?(value) == LandObsGrammar.valid_value?(value), inspect(value)
      end
    end

    property "SQL and Elixir agree on in-shape values around the bounds" do
      check all(
              t <- integer(-950..650),
              mslp <- integer(800..1150),
              rh <- integer(-5..105),
              vis <- integer(-5..10_050),
              max_runs: 500
            ) do
        value = Enum.join([t, mslp, rh, vis], ";")
        assert sql_valid?(value) == LandObsGrammar.valid_value?(value), value
      end
    end
  end

  defp sql_valid?(value), do: sql_one("SELECT wallop_landobs_valid_value($1)", [value])

  defp constraint_def(name) do
    sql_one(
      "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
      [name]
    )
  end
end
