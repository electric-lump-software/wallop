defmodule WallopCore.Entropy.FrequencyWindowWorker do
  @moduledoc """
  Fetches the 8 GB grid frequency readings of one window start T and stores
  them once, for every draw waiting on T, of either tag
  (`Windows.waiting_tags/0`).

  One live job per T (unique on `freq_start` among incomplete jobs),
  however many draws lock for it. A finished job (completed, cancelled or
  discarded) never blocks a new one for its T. A second job is harmless:
  the store is first write wins. Build it with `new_for_start/1`, which
  writes T in one canonical form and schedules the first poll for
  T + 135 s.

  Each run fetches the window and then reads the database clock. That clock
  alone decides what may be stored, by `window_state/2`: [T + 105 s, F],
  the window the store's insert trigger enforces. A run past F stops
  without storing. Only a valid window is stored; an invalid one stores
  nothing and the job polls again.

  The store is one call per T, made outside any transaction. If it is
  refused because T already has a row, T is done. Any other refusal is
  reported and the job polls again.

  Errors never fail the job before F: they are counted in telemetry, and
  the job snoozes and polls again. Snoozing doesn't use up attempts, so the
  fetch window, not the attempt count, ends the job. The HTTP client never
  retries; this polling is the retry, and it can't change a stored value.

  Logs and telemetry carry only enumerated terms (the client's error terms,
  exception kinds), never response bodies or request structs.

  Telemetry:

    * `[:wallop_core, :frequency, :poll]`, `%{count: 1}`,
      `%{freq_start, ok?, error}`;
    * `[:wallop_core, :frequency, :stored]`, `%{count: 1}`, `%{freq_start}`;
    * `[:wallop_core, :frequency, :store_refused]`, `%{count: 1}`,
      `%{freq_start, reason}`, while T still has no row;
    * `[:wallop_core, :frequency, :poll_error]`, `%{count: 1}`,
      `%{freq_start, kind}`: the run raised, exited or threw.
  """
  use Oban.Worker,
    # Its own queue: Elexon polls never hold Land Obs fetch slots.
    queue: :frequency,
    # Snoozes don't count against this; only crashes and timeouts do.
    max_attempts: 100,
    unique: [period: :infinity, keys: [:freq_start], states: :incomplete]

  require Logger

  alias WallopCore.DbClock
  alias WallopCore.Entropy.ElexonFreqClient
  alias WallopCore.Frequency.{Schedule, Windows}

  # The client's own timeouts are per chunk, so each fetch is capped here.
  # Fetch cap + store (5 s statement timeout) + reads stay under the job
  # timeout, and the job timeout stays under the 20 s poll interval.
  @fetch_timeout_ms 8_000
  @job_timeout_ms 15_000
  # The last poll is made at least this long before F.
  @deadline_margin_seconds 2

  @doc "The job for window start `t` (UTC, whole seconds, on the 15 s grid); raises otherwise."
  @spec new_for_start(DateTime.t()) :: Ecto.Changeset.t()
  def new_for_start(%DateTime{} = t) do
    if window_start?(t) do
      new(%{freq_start: start_arg(t)}, scheduled_at: first_poll_at(t))
    else
      raise ArgumentError, "freq_start must be a UTC window start, got #{DateTime.to_iso8601(t)}"
    end
  end

  @doc """
  The canonical `freq_start` job argument: UTC, whole seconds, ISO 8601
  (`"2026-10-14T19:54:00Z"`). Uniqueness compares this string.
  """
  @spec start_arg(DateTime.t()) :: String.t()
  def start_arg(%DateTime{} = t),
    do:
      t |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc """
  What may be stored for T at database time `now`: `:open` within
  [T + 105 s, F], `:not_yet` before, `:closed` after. Mirrors
  `wallop_freq_store_allowed()` exactly.
  """
  @spec window_state(DateTime.t(), DateTime.t()) :: :not_yet | :open | :closed
  def window_state(%DateTime{} = now, %DateTime{} = t) do
    cond do
      DateTime.compare(now, Schedule.store_from(t)) == :lt -> :not_yet
      DateTime.compare(now, Schedule.fetch_deadline(t)) != :gt -> :open
      true -> :closed
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: @job_timeout_ms

  @impl Oban.Worker
  def backoff(_job), do: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"freq_start" => iso}}) when is_binary(iso) do
    # Only the canonical form is run, so every job for T has the same
    # argument and uniqueness can't be sidestepped by another spelling.
    with {:ok, t, 0} <- DateTime.from_iso8601(iso),
         t = %{t | microsecond: {0, 6}},
         true <- iso == start_arg(t),
         true <- window_start?(t) do
      run(t)
    else
      _ -> {:cancel, :invalid_freq_start}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_freq_start}

  defp run(t) do
    now = DbClock.now()

    cond do
      window_state(now, t) == :closed ->
        :ok

      DateTime.compare(now, first_poll_at(t)) == :lt ->
        {:snooze, seconds_until(first_poll_at(t), now)}

      Windows.pending_draw_ids(t) == [] ->
        :ok

      true ->
        poll(t)
    end
  rescue
    e -> poll_failed(t, :error, e.__struct__)
  catch
    :exit, _ -> poll_failed(t, :exit, nil)
    :throw, _ -> poll_failed(t, :throw, nil)
  end

  defp poll(t) do
    result = fetch(t)
    report(t, result)

    # The clock is read after fetching, so the decision is as close to the
    # store as it can be. The trigger checks it again on its own clock.
    now = DbClock.now()

    case window_state(now, t) do
      :open ->
        with {:ok, window} <- result, do: store(t, window)
        if Windows.pending_draw_ids(t) == [], do: :ok, else: next_poll(now, t)

      :closed ->
        :ok

      :not_yet ->
        {:snooze, seconds_until(Schedule.store_from(t), now)}
    end
  end

  defp fetch(t) do
    task = Task.async(fn -> fetch_one(t) end)

    case Task.yield(task, @fetch_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :poll_timeout}
      {:exit, _} -> {:raised, :exit, nil}
    end
  end

  defp fetch_one(t) do
    ElexonFreqClient.fetch_window(t)
  rescue
    e -> {:raised, :error, e.__struct__}
  catch
    :exit, _ -> {:raised, :exit, nil}
    :throw, _ -> {:raised, :throw, nil}
  end

  defp report(t, {:raised, kind, module} = result) do
    poll_error(t, kind, module)
    emit_poll(t, result)
  end

  defp report(t, result), do: emit_poll(t, result)

  defp emit_poll(t, result) do
    error =
      case result do
        {:ok, _} -> nil
        {:error, reason} -> reason
        {:raised, kind, _module} -> {:raised, kind}
      end

    :telemetry.execute([:wallop_core, :frequency, :poll], %{count: 1}, %{
      freq_start: t,
      ok?: error == nil,
      error: error
    })
  end

  defp store(t, %{value: value, raw: raw}) do
    case Windows.store(t, value, raw) do
      {:ok, _} ->
        :telemetry.execute([:wallop_core, :frequency, :stored], %{count: 1}, %{freq_start: t})

      {:error, reason} ->
        # Refused because T already has a row: another run stored it first,
        # and that row is T's window. Nothing to report.
        if Windows.for_start(t) == nil, do: store_refused(t, reason)
    end
  end

  defp store_refused(t, reason) do
    reason =
      if reason in [:nested_transaction, :raw_does_not_give_value], do: reason, else: :refused

    Logger.warning("FrequencyWindowWorker: store for #{start_arg(t)} refused (#{reason})")

    :telemetry.execute([:wallop_core, :frequency, :store_refused], %{count: 1}, %{
      freq_start: t,
      reason: reason
    })
  end

  # Stops only when the database clock says F has passed. If the database
  # can't be read, it snoozes; the BEAM clock is never used.
  defp poll_failed(t, kind, module) do
    poll_error(t, kind, module)

    case db_clock() do
      {:ok, now} ->
        if window_state(now, t) == :closed,
          do: :ok,
          else: {:snooze, Schedule.poll_interval_seconds()}

      :error ->
        {:snooze, Schedule.poll_interval_seconds()}
    end
  end

  defp poll_error(t, kind, module) do
    detail = if module, do: " #{inspect(module)}", else: ""
    Logger.error("FrequencyWindowWorker: poll for #{start_arg(t)} failed (#{kind}#{detail})")

    :telemetry.execute([:wallop_core, :frequency, :poll_error], %{count: 1}, %{
      freq_start: t,
      kind: kind
    })
  end

  defp db_clock do
    {:ok, DbClock.now()}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp window_start?(%DateTime{time_zone: "Etc/UTC", microsecond: {0, _}} = t),
    do: Integer.mod(DateTime.to_unix(t), Schedule.spacing_seconds()) == 0

  defp window_start?(_), do: false

  defp first_poll_at(t),
    do: DateTime.add(Schedule.store_from(t), Schedule.first_poll_after_store_from_seconds())

  @doc false
  # The next poll, at least @deadline_margin_seconds before F; when there is
  # no whole second left for that, polling stops.
  @spec next_poll(DateTime.t(), DateTime.t()) :: {:snooze, pos_integer()} | :ok
  def next_poll(now, t) do
    left = DateTime.diff(Schedule.fetch_deadline(t), now) - @deadline_margin_seconds
    if left >= 1, do: {:snooze, min(Schedule.poll_interval_seconds(), left)}, else: :ok
  end

  defp seconds_until(t, now), do: max(DateTime.diff(t, now), 1)
end
