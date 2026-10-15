defmodule WallopCore.Weather.ScheduleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias WallopCore.Weather.Schedule

  @genesis 1_692_803_367

  defp grid_point(unix),
    do: DateTime.from_unix!((unix - Integer.mod(unix - @genesis, 3)) * 1_000_000, :microsecond)

  describe "v6_schedule/1, worked example (W = 40 min)" do
    test "a 20:00 draw observes 19:00, closes the fetch at 19:40 and locks by 18:14" do
      assert {:ok, s} = Schedule.v6_schedule(~U[2026-10-14 20:00:00.000000Z])
      assert s.round == 33_068_212
      assert s.expected_result_at == ~U[2026-10-14 20:00:00.000000Z]
      assert s.weather_time == ~U[2026-10-14 19:00:00.000000Z]
      assert s.backup_cutover == ~U[2026-10-14 19:30:00.000000Z]
      assert s.fetch_deadline == ~U[2026-10-14 19:40:00.000000Z]
      assert s.latest_lock_at == ~U[2026-10-14 18:14:00.000000Z]
    end

    test "refuses sub-second, off-grid and pre-genesis times" do
      assert {:error, :sub_second} = Schedule.v6_schedule(~U[2026-10-14 20:00:00.500000Z])
      assert {:error, :not_on_grid} = Schedule.v6_schedule(~U[2026-10-14 20:00:01.000000Z])
      assert {:error, :before_genesis} = Schedule.v6_schedule(~U[2020-01-01 00:00:00.000000Z])
    end

    test "every whole minute is on the grid" do
      assert {:ok, _} = Schedule.v6_schedule(~U[2026-10-14 20:07:00.000000Z])
    end
  end

  describe "properties" do
    property "weather_time is the latest whole hour h with h + W + 60s <= pub(R)" do
      check all(unix <- integer(1_800_000_000..1_900_000_000)) do
        draw_at = grid_point(unix)
        {:ok, s} = Schedule.v6_schedule(draw_at)
        w = Schedule.fetch_window_seconds()
        wt = DateTime.to_unix(s.weather_time)
        pub = DateTime.to_unix(s.expected_result_at)

        assert s.expected_result_at == draw_at
        assert rem(wt, 3600) == 0
        assert wt + w + 60 <= pub
        assert wt + 3600 + w + 60 > pub
        assert DateTime.to_unix(s.latest_lock_at) == wt - 46 * 60
        assert Schedule.pub_time(s.round) == draw_at
      end
    end

    property "default_draw_at is the earliest grid point whose weather_time is far enough ahead" do
      check all(unix <- integer(1_800_000_000..1_900_000_000), us <- integer(0..999_999)) do
        now = DateTime.from_unix!(unix * 1_000_000 + us, :microsecond)
        draw_at = Schedule.default_draw_at(now)
        {:ok, s} = Schedule.v6_schedule(draw_at)
        {:ok, prev} = Schedule.v6_schedule(DateTime.add(draw_at, -3, :second))

        assert Schedule.lock_allowed?(now, s.weather_time)
        assert DateTime.diff(s.weather_time, now) >= 46 * 60
        assert DateTime.compare(prev.weather_time, s.weather_time) == :lt
      end
    end
  end

  test "worked default: at 18:00 the default is 19:41 (observing 19:00)" do
    assert Schedule.default_draw_at(~U[2026-10-14 18:00:00.000000Z]) ==
             ~U[2026-10-14 19:41:00.000000Z]
  end

  test "lock_allowed? is inclusive at latest_lock_at" do
    wt = ~U[2026-10-14 19:00:00.000000Z]
    assert Schedule.lock_allowed?(~U[2026-10-14 18:14:00.000000Z], wt)
    refute Schedule.lock_allowed?(~U[2026-10-14 18:14:00.000001Z], wt)
  end

  test "within_cap? allows exactly 7 days (201,600 rounds)" do
    now = ~U[2026-10-14 12:00:00.000000Z]
    assert Schedule.within_cap?(now, DateTime.add(now, 604_800))
    refute Schedule.within_cap?(now, DateTime.add(now, 604_801))
  end
end
