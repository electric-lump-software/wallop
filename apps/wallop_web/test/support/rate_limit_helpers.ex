defmodule WallopWeb.RateLimitHelpers do
  @moduledoc """
  Test helpers for rate-limit windows.

  Hammer windows are aligned to the wall clock, so a test that hits a limit
  and then expects a deny can straddle a window edge and see a fresh budget.
  """

  @window_ms 60_000
  @margin_ms 5_000

  @doc """
  Sleeps until the next minute when fewer than five seconds remain in the
  current one, so the rest of the test runs inside a single window.
  """
  @spec await_fresh_window() :: :ok
  def await_fresh_window do
    remaining = @window_ms - rem(System.system_time(:millisecond), @window_ms)

    if remaining < @margin_ms do
      Process.sleep(remaining + 50)
    end

    :ok
  end
end
