defmodule WallopWeb.RateLimit.Sweeper do
  @moduledoc """
  Owns the rate-limit ETS tables and periodically evicts closed windows.

  ## Why this exists

  Each rate-limit plug used to create its table lazily, via `ensure_table/0`,
  from whichever process happened to serve the first request. An ETS table
  belongs to the process that created it, so the table — and every counter in
  it — was destroyed the moment that connection process exited. The documented
  per-window caps therefore did not hold across connections: a client that
  opened a fresh connection got a fresh budget.

  Creating the tables here, from a process in the supervision tree, gives them
  a lifetime that matches the node rather than a request.

  That fix creates a second obligation. A counter row is only rewritten when
  the same key is seen again inside its window, so a key seen once and never
  again would sit in the table for the life of the node. Now that entries
  genuinely persist, something has to reclaim them — hence the sweep.

  The plugs are unchanged in behaviour: their `ensure_table/0` is a no-op once
  the table exists, and remains as a fallback so the plugs still work if this
  process is not running (notably in unit tests that exercise a plug directly).
  """

  use GenServer

  alias WallopWeb.Plugs.ProofPreLockRateLimit
  alias WallopWeb.Plugs.SelfCheckRateLimit

  @limiters [ProofPreLockRateLimit, SelfCheckRateLimit]

  @sweep_interval :timer.minutes(1)

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Modules whose tables this process owns and sweeps."
  def limiters, do: @limiters

  @impl GenServer
  def init(_opts) do
    Enum.each(@limiters, & &1.ensure_table())

    {:ok, schedule_sweep(%{})}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()

    {:noreply, schedule_sweep(state)}
  end

  @doc """
  Deletes every entry whose window closed before `now`.

  Returns the number of entries removed. Exposed for tests and for manual
  invocation from a remote console.
  """
  def sweep(now \\ System.monotonic_time(:millisecond)) do
    Enum.reduce(@limiters, 0, fn limiter, removed ->
      removed + sweep_table(limiter.table(), now - limiter.window_ms())
    end)
  end

  # Rows are `{key, count, window_start_monotonic_ms}` across every limiter, so
  # one match spec covers all of them: drop rows whose window opened before the
  # cutoff. Those rows can only ever be treated as expired by `check_rate/1`.
  defp sweep_table(table, cutoff) do
    case :ets.whereis(table) do
      :undefined ->
        0

      _tid ->
        :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end
  end

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, @sweep_interval)

    state
  end
end
