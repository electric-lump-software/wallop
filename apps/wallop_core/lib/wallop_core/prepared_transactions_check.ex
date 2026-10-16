defmodule WallopCore.PreparedTransactionsCheck do
  @moduledoc """
  Boot-time check that the database has prepared transactions switched off
  (`max_prepared_transactions = 0`).

  The observation store refuses a row whose transaction commits after the
  fetch deadline, with a check that runs at commit. A prepared transaction
  would run that check at PREPARE, before the deadline, and could then be
  committed or rolled back once the drand round is known. With prepared
  transactions off, that can't happen.

  A non-zero setting is not fatal (yet): it logs an error and emits
  `[:wallop_core, :db, :prepared_transactions_enabled]` with the setting as
  `%{max_prepared_transactions: n}`, for alerting. Runs once, after the repo
  starts, and never stops the app. Switched off in the test config, whose
  invariant suite checks the test database directly.
  """

  require Logger

  alias WallopCore.Repo

  @event [:wallop_core, :db, :prepared_transactions_enabled]

  @doc "The telemetry event emitted when prepared transactions are on."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "A child spec that runs the check once, in the background, if enabled."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :temporary}
  end

  @doc "Reads the setting and reports it. Never raises."
  @spec run() :: :ok | {:alert, String.t()} | {:error, term()}
  def run do
    %{rows: [[value]]} = Repo.query!("SHOW max_prepared_transactions")
    report(value)
  rescue
    e ->
      Logger.warning("Could not read max_prepared_transactions: #{Exception.message(e)}")
      {:error, e}
  end

  @doc "Reports a `max_prepared_transactions` value: `:ok` for \"0\", otherwise an alert."
  @spec report(String.t()) :: :ok | {:alert, String.t()}
  def report("0"), do: :ok

  def report(value) do
    Logger.error(
      "max_prepared_transactions is #{value}, not 0. A prepared transaction could " <>
        "hold an observation store past its fetch deadline. Set it to 0."
    )

    :telemetry.execute(@event, %{max_prepared_transactions: parse(value)}, %{})
    {:alert, value}
  end

  defp parse(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> -1
    end
  end
end
