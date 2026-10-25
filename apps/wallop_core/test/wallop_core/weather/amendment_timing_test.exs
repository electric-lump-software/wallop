defmodule WallopCore.Weather.AmendmentTimingTest do
  @moduledoc """
  The timing facts the Middle-Wallop-only rule relies on, for every draw
  second of the hour (pub = wt + 1860 + d, d in 0..3597 step 3).
  """
  use ExUnit.Case, async: true

  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Weather.Schedule

  test "the weather schedule carries the round's window start" do
    {:ok, s} = Schedule.schedule(~U[2026-10-14 20:00:00Z])
    assert s.freq_start == ~U[2026-10-14 19:54:00.000000Z]
    refute Map.has_key?(s, :freq_fetch_deadline)
    assert s.freq_start == FreqSchedule.freq_start_for_round(s.round)
  end

  test "the frequency window opens before weather settles only below wt + 35m15s" do
    wt = ~U[2026-10-25 01:00:00Z] |> DateTime.to_unix()

    opens_first =
      for d <- 0..3597//3,
          {:ok, s} = Schedule.schedule(DateTime.from_unix!(wt + 1860 + d)),
          DateTime.to_unix(s.freq_start) + 105 < DateTime.to_unix(s.fetch_deadline) + 60,
          do: d

    closes_first =
      for d <- 0..3597//3,
          {:ok, s} = Schedule.schedule(DateTime.from_unix!(wt + 1860 + d)),
          DateTime.to_unix(FreqSchedule.fetch_deadline(s.freq_start)) <
            DateTime.to_unix(s.fetch_deadline) + 60,
          do: d

    assert opens_first == Enum.to_list(0..252//3)
    assert closes_first == [0, 3, 6, 9, 12]
  end
end
