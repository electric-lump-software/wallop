defmodule WallopCore.PreparedTransactionsCheck do
  @moduledoc """
  Checks that the database has prepared transactions switched off
  (`max_prepared_transactions = 0`): once at boot, then hourly.

  The observation store refuses a row whose transaction commits after the
  fetch deadline, with a check that runs at commit. A prepared transaction
  would run that check at PREPARE, before the deadline, and could then be
  committed or rolled back once the drand round is known. With prepared
  transactions off, that can't happen. The setting can change under a running
  app (a database restart with new settings), hence the hourly re-check.

  A non-zero setting is not fatal (yet). It logs an error and emits
  `[:wallop_core, :db, :prepared_transactions_enabled]` with
  `%{max_prepared_transactions: n}`. A setting that can't be read is retried
  once after a short delay; if it still can't be read, it logs an error and
  emits `[:wallop_core, :db, :prepared_transactions_unreadable]` with
  `%{count: 1}`. Neither ever stops the app.

  Every app that starts wallop_core runs this check. wallop-app shares the
  database, so the same alert may be logged twice, once per app.

  A small GenServer, not an Oban job: core's Oban instance only inserts jobs.
  Switched off in the test config, whose invariant suite checks the test
  database directly.
  """
  use GenServer

  require Logger

  alias WallopCore.Repo

  @enabled [:wallop_core, :db, :prepared_transactions_enabled]
  @unreadable [:wallop_core, :db, :prepared_transactions_unreadable]
  @interval_ms :timer.hours(1)
  @retry_delay_ms :timer.seconds(5)

  @doc "The event emitted when prepared transactions are on."
  @spec event() :: [atom()]
  def event, do: @enabled

  @doc "The event emitted when the setting can't be read, after one retry."
  @spec unreadable_event() :: [atom()]
  def unreadable_event, do: @unreadable

  @doc """
  Options (for tests): `:interval_ms` (default 1 hour), `:retry_delay_ms`
  (default 5 s), `:read` (a 0-arity function returning the setting as text;
  default reads the database), `:name`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      retry_delay_ms: Keyword.get(opts, :retry_delay_ms, @retry_delay_ms),
      read: Keyword.get(opts, :read, &read/0)
    }

    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    run(state.read, state.retry_delay_ms)
    Process.send_after(self(), :check, state.interval_ms)
    {:noreply, state}
  end

  @doc """
  Reads the setting (retrying once after `retry_delay_ms`) and reports it.
  Never raises.
  """
  @spec run((-> String.t()), non_neg_integer()) ::
          :ok | {:alert, String.t()} | {:unreadable, String.t()}
  def run(read \\ &read/0, retry_delay_ms \\ @retry_delay_ms) do
    case attempt(read) do
      {:ok, value} ->
        report(value)

      {:error, _first} ->
        Process.sleep(retry_delay_ms)

        case attempt(read) do
          {:ok, value} -> report(value)
          {:error, reason} -> unreadable(reason)
        end
    end
  end

  @doc "Reports a `max_prepared_transactions` value: `:ok` for \"0\", otherwise an alert."
  @spec report(String.t()) :: :ok | {:alert, String.t()}
  def report("0"), do: :ok

  def report(value) do
    Logger.error(
      "max_prepared_transactions is #{value}, not 0. A prepared transaction could " <>
        "hold an observation store past its fetch deadline. Set it to 0."
    )

    :telemetry.execute(@enabled, %{max_prepared_transactions: parse(value)}, %{})
    {:alert, value}
  end

  defp unreadable(reason) do
    Logger.error("Could not read max_prepared_transactions (retried once): #{reason}")
    :telemetry.execute(@unreadable, %{count: 1}, %{})
    {:unreadable, reason}
  end

  defp attempt(read) do
    {:ok, read.()}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp read do
    %{rows: [[value]]} = Repo.query!("SHOW max_prepared_transactions")
    value
  end

  defp parse(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end
end
