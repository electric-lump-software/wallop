defmodule WallopWeb.RateLimit.SweeperTest do
  use ExUnit.Case, async: false

  alias WallopWeb.Plugs.KeyRateLimit
  alias WallopWeb.Plugs.ProofPreLockRateLimit
  alias WallopWeb.Plugs.RateLimit
  alias WallopWeb.Plugs.SelfCheckRateLimit
  alias WallopWeb.RateLimit.Sweeper

  setup do
    Enum.each(Sweeper.limiters(), & &1.reset())

    :ok
  end

  describe "table ownership" do
    test "tables outlive the process that first touches them" do
      # Regression: the tables were previously created by whichever request
      # process served the first request, so they were destroyed when that
      # connection closed and every counter reset with them.
      {pid, ref} =
        spawn_monitor(fn ->
          RateLimit.ensure_table()
          RateLimit.check_rate("203.0.113.9")
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      assert :ets.whereis(RateLimit.table()) != :undefined
      assert [{_key, 1, _window}] = :ets.lookup(RateLimit.table(), {:rate, "203.0.113.9"})
    end

    test "tables are owned by the sweeper, not a transient process" do
      for limiter <- Sweeper.limiters() do
        assert :ets.info(limiter.table(), :owner) == Process.whereis(Sweeper),
               "#{inspect(limiter)} table is not owned by the sweeper"
      end
    end
  end

  describe "sweep/1" do
    test "removes entries whose window has closed" do
      RateLimit.check_rate("198.51.100.1")
      SelfCheckRateLimit.check_rate("198.51.100.2")
      ProofPreLockRateLimit.check_rate("198.51.100.3")
      KeyRateLimit.check_rate("some-api-key-id")

      assert :ets.info(RateLimit.table(), :size) == 1
      assert :ets.info(SelfCheckRateLimit.table(), :size) == 1
      assert :ets.info(ProofPreLockRateLimit.table(), :size) == 1
      assert :ets.info(KeyRateLimit.table(), :size) == 1

      # Sweep as if a full window had elapsed since those entries were written.
      future = System.monotonic_time(:millisecond) + RateLimit.window_ms() + 1

      assert Sweeper.sweep(future) == 4

      for limiter <- Sweeper.limiters() do
        assert :ets.info(limiter.table(), :size) == 0,
               "#{inspect(limiter)} table was not swept"
      end
    end

    test "keeps entries whose window is still open" do
      RateLimit.check_rate("198.51.100.4")

      assert Sweeper.sweep() == 0
      assert :ets.info(RateLimit.table(), :size) == 1
    end

    test "does not disturb an in-flight counter" do
      # A key still inside its window must keep counting across a sweep,
      # otherwise sweeping would hand out a fresh budget.
      for _ <- 1..3, do: RateLimit.check_rate("198.51.100.5")

      assert Sweeper.sweep() == 0
      assert [{_key, 3, _window}] = :ets.lookup(RateLimit.table(), {:rate, "198.51.100.5"})
    end

    test "is a no-op when there is nothing to reclaim" do
      assert Sweeper.sweep() == 0
    end
  end
end
