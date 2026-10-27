defmodule WallopCore.Attacks.FreqLockStraddleTest do
  @moduledoc """
  A frequency lock must not commit after T - 60 s. Unlike the weather
  deadline (always hh:14:00), T - 60 s falls every 15 seconds, so a late
  commit can be staged on demand: the lock UPDATE runs in time, the
  transaction is held past the deadline, and the commit-time check
  (`check_v6_draw_lock_commit`, on `clock_timestamp()`) refuses it. Real
  commits, outside the sandbox; every fixture is deleted afterwards.
  """
  use WallopCore.InvariantCase, async: false

  import WallopCore.UnboxedHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Resources.Draw

  @late "v6 lock is too late for this draw time"

  defp schedule_closing_soon do
    now = DateTime.to_unix(DateTime.utc_now())
    t = now + 68 + Integer.mod(-(now + 68), 15)

    {:ok, s} =
      FreqSchedule.schedule(
        Quicknet.pub_time(Quicknet.round_at_or_after(DateTime.from_unix!(t + 360)))
      )

    ^t = DateTime.to_unix(s.freq_start)
    s
  end

  defp open_draw do
    {operator, draw} =
      unboxed(fn ->
        {operator, key} = create_freq_operator()
        {operator, open_draw_with_entries(key)}
      end)

    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    draw
  end

  defp lock_and_commit(draw, s, before_commit) do
    unboxed(fn ->
      {:ok, _} =
        Repo.transaction(
          fn ->
            nil = raw_freq_lock(draw, s)
            before_commit.()
          end,
          timeout: 60_000
        )
    end)

    :committed
  rescue
    e in Postgrex.Error -> {:refused, e.postgres.message}
  end

  test "a lock made in time but committed after T - 60 s is refused at commit" do
    draw = open_draw()
    s = schedule_closing_soon()

    assert lock_and_commit(draw, s, fn -> wait_until_db_clock_after(s.latest_lock_at) end) ==
             {:refused, @late}

    assert unboxed(fn -> Ash.get!(Draw, draw.id, authorize?: false).status end) == :open
  end

  test "control: a lock committed before T - 60 s is kept" do
    draw = open_draw()

    {:ok, s} =
      FreqSchedule.schedule(FreqSchedule.default_draw_at(DateTime.add(DateTime.utc_now(), 600)))

    assert lock_and_commit(draw, s, fn -> :ok end) == :committed

    assert unboxed(fn -> Ash.get!(Draw, draw.id, authorize?: false).status end) ==
             :awaiting_entropy
  end
end
