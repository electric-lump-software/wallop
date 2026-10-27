defmodule WallopCore.Frequency.ScheduleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule

  defp grid_point(unix),
    do: Quicknet.pub_time(Quicknet.round_at_or_after(DateTime.from_unix!(unix)))

  describe "schedule/1, worked example (W_freq = 240 s, M = 15 s)" do
    setup do
      assert Schedule.fetch_window_seconds() == 240, "recompute these examples for the new W_freq"
      assert Schedule.margin_seconds() == 15, "recompute these examples for the new M"
      :ok
    end

    test "a 20:00:00 draw reads 19:54:00 to 19:55:45, closes the fetch at 19:59:45 and locks by 19:53:00" do
      assert {:ok, s} = Schedule.schedule(~U[2026-10-14 20:00:00.000000Z])
      assert s.round == 33_068_212
      assert s.freq_start == ~U[2026-10-14 19:54:00.000000Z]
      assert s.store_from == ~U[2026-10-14 19:55:45.000000Z]
      assert s.fetch_deadline == ~U[2026-10-14 19:59:45.000000Z]
      assert s.latest_lock_at == ~U[2026-10-14 19:53:00.000000Z]
      assert s.expected_result_at == ~U[2026-10-14 20:00:00.000000Z]
    end

    test "a draw 3 s later shares the window; 15 s later moves it on by one reading; 3 s earlier moves it back" do
      {:ok, a} = Schedule.schedule(~U[2026-10-14 20:00:03.000000Z])
      assert a.freq_start == ~U[2026-10-14 19:54:00.000000Z]
      assert a.fetch_deadline == ~U[2026-10-14 19:59:45.000000Z]

      {:ok, b} = Schedule.schedule(~U[2026-10-14 20:00:15.000000Z])
      assert b.freq_start == ~U[2026-10-14 19:54:15.000000Z]

      {:ok, c} = Schedule.schedule(~U[2026-10-14 19:59:57.000000Z])
      assert c.freq_start == ~U[2026-10-14 19:53:45.000000Z]
    end

    test "worked default: at 18:00:00 the default draw time is 18:07:30" do
      assert Schedule.default_draw_at(~U[2026-10-14 18:00:00.000000Z]) ==
               ~U[2026-10-14 18:07:30.000000Z]
    end
  end

  test "refuses sub-second, off-grid and pre-genesis times" do
    assert {:error, :sub_second} = Schedule.schedule(~U[2026-10-14 20:00:00.500000Z])
    assert {:error, :not_on_grid} = Schedule.schedule(~U[2026-10-14 20:00:01.000000Z])
    assert {:error, :before_genesis} = Schedule.schedule(~U[2020-01-01 00:00:00.000000Z])
  end

  test "the eight reading times are 15 s apart, in time order" do
    t = ~U[2026-10-14 19:54:15.000000Z]
    times = Schedule.reading_times(t)
    assert times == Enum.map(0..7, &DateTime.add(t, 15 * &1))
    assert List.last(times) == Schedule.store_from(t)
  end

  test "lock_allowed? is inclusive at latest_lock_at, to the microsecond" do
    t = ~U[2026-10-14 19:54:15.000000Z]
    assert Schedule.lock_allowed?(~U[2026-10-14 19:53:15.000000Z], t)
    refute Schedule.lock_allowed?(~U[2026-10-14 19:53:15.000001Z], t)
  end

  test "within_cap? allows exactly 7 days" do
    now = ~U[2026-10-14 12:00:00.000000Z]
    assert Schedule.within_cap?(now, DateTime.add(now, 604_800))
    refute Schedule.within_cap?(now, DateTime.add(now, 604_801))
  end

  describe "properties" do
    property "freq_start is the latest 15 s boundary T with T + 105 s + W_freq + M <= pub(R)" do
      w = Schedule.fetch_window_seconds()
      m = Schedule.margin_seconds()

      check all(unix <- integer(1_800_000_000..1_900_000_000)) do
        draw_at = grid_point(unix)
        {:ok, s} = Schedule.schedule(draw_at)
        t = DateTime.to_unix(s.freq_start)
        pub = DateTime.to_unix(s.expected_result_at)

        assert s.expected_result_at == draw_at
        assert Schedule.pub_time(s.round) == draw_at
        assert rem(t, 15) == 0
        assert t + 105 + w + m <= pub
        assert t + 15 + 105 + w + m > pub
        assert DateTime.to_unix(s.store_from) == t + 105
        assert DateTime.to_unix(s.fetch_deadline) == t + 105 + w
        assert DateTime.to_unix(s.fetch_deadline) <= pub - m
        assert DateTime.to_unix(s.latest_lock_at) == t - 60
        assert (pub - DateTime.to_unix(s.latest_lock_at)) in (165 + w + m)..(179 + w + m)
      end
    end

    property "default_draw_at is the earliest grid point whose window starts at least 90 s after now" do
      check all(unix <- integer(1_800_000_000..1_900_000_000), us <- integer(0..999_999)) do
        now = DateTime.from_unix!(unix * 1_000_000 + us, :microsecond)
        draw_at = Schedule.default_draw_at(now)
        {:ok, s} = Schedule.schedule(draw_at)
        {:ok, prev} = Schedule.schedule(DateTime.add(draw_at, -3, :second))

        assert Schedule.lock_allowed?(DateTime.add(now, 29, :second), s.freq_start)
        assert DateTime.diff(prev.freq_start, now, :microsecond) < 90_000_000
      end
    end
  end
end
