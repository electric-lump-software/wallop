defmodule WallopCore.Entropy.WeatherObservationWorker do
  @moduledoc """
  Fetches the Land Observations reading for one observation hour and stores
  it once for that hour, for every observation-weather draw waiting on it.

  One live job per hour (unique on `weather_time` among incomplete jobs),
  however many draws lock for it. A finished job (completed, cancelled or
  discarded) never blocks a new one for its hour, so a stray finished row
  can't silently swallow the hour's fetch. A second job is harmless: the
  store is first write wins, so it can't change a stored reading. Build it with `new_for_hour/1`, which writes the hour in one
  canonical form and schedules the first poll for weather_time + 5 min.

  Each run polls Middle Wallop once and then reads the database clock. That
  clock alone decides whether the reading may be stored (`window_state/2`):
  from weather_time to the fetch deadline F, the window the store's insert
  trigger enforces. Polling once a minute from weather_time + 5 min to F
  costs at most 26 calls an hour. A run past F stops without storing.

  The store is one call per hour, made outside any transaction. If it is
  refused because the hour already has a row (another run got there first),
  the hour is done. Any other refusal is reported and the job polls again.

  Errors never fail the job before F: they are counted in telemetry, and the
  job snoozes and polls again, since a job lost to an error would turn a real
  observation into a fallback. Snoozing doesn't use up attempts (Oban 2.23
  raises `max_attempts` on each snooze), so the fetch window, not the attempt
  count, ends the job. The HTTP client never retries; this polling is the
  retry, and it can't change a stored value, because the first store for an
  hour is the only one.

  Logs and telemetry carry only enumerated terms (the client's error terms,
  exception module names), never response bodies, request structs or the
  API key.

  Telemetry (`station`, when set, is always `"wmo-03749"`):

    * `[:wallop_core, :weather, :poll]`, `%{count: 1}`,
      `%{station, weather_time, ok?, error}`: one per poll, including a
      fetch that raised (`error: {:raised, kind}`);
    * `[:wallop_core, :weather, :stored]`, `%{count: 1}`,
      `%{station, weather_time}`: the hour's reading was stored by this run;
    * `[:wallop_core, :weather, :store_refused]`, `%{count: 1}`,
      `%{station, weather_time, reason}`: a store was refused and the hour
      still has no row (`reason` is `:nested_transaction` or `:refused`);
    * `[:wallop_core, :weather, :poll_error]`, `%{count: 1}`,
      `%{weather_time, station, kind}`: a fetch (`station` set) or the run
      (`station: nil`) raised (`:error`), exited (`:exit`) or threw
      (`:throw`).
  """
  use Oban.Worker,
    queue: :weather,
    # Snoozes don't count against this; only crashes and timeouts do.
    max_attempts: 100,
    unique: [period: :infinity, keys: [:weather_time], states: :incomplete]

  require Logger

  alias WallopCore.DbClock
  alias WallopCore.Entropy.LandObsClient
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  # Tests swap in a wrapper around the real client; see
  # WallopCore.Test.WindowedLandObsClient. Fixed at compile time.
  @client Application.compile_env(:wallop_core, [__MODULE__, :land_obs_client], LandObsClient)

  if @client != LandObsClient and Mix.env() != :test do
    raise CompileError,
      description:
        "#{inspect(__MODULE__)}: :land_obs_client may be set only in the test " <>
          "environment (got #{inspect(@client)} in #{Mix.env()}). Outside tests the " <>
          "worker always uses #{inspect(LandObsClient)}."
  end

  # The client's own timeouts are per chunk (connect 5 s, receive 10 s), so
  # each fetch is also capped here.
  # Fetch cap + store (5 s statement timeout) + reads stay under the job
  # timeout, and the job timeout stays under the poll interval.
  @fetch_timeout_ms 20_000
  @job_timeout_ms 30_000
  # The last poll is made at least this long before F.
  @deadline_margin_seconds 5

  @doc """
  The job for observation hour `weather_time`, which must be a whole UTC
  hour (raises `ArgumentError` otherwise).
  """
  @spec new_for_hour(DateTime.t()) :: Ecto.Changeset.t()
  def new_for_hour(
        %DateTime{time_zone: "Etc/UTC", minute: 0, second: 0, microsecond: {0, _}} =
          weather_time
      ) do
    new(%{weather_time: hour_arg(weather_time)},
      scheduled_at: first_poll_at(weather_time)
    )
  end

  def new_for_hour(%DateTime{} = weather_time) do
    raise ArgumentError,
          "weather_time must be a whole UTC hour, got #{DateTime.to_iso8601(weather_time)}"
  end

  @doc """
  The canonical `weather_time` job argument: UTC, whole seconds, ISO 8601
  (`"2026-10-14T19:00:00Z"`). Uniqueness compares this string, so every
  inserter must use it.
  """
  @spec hour_arg(DateTime.t()) :: String.t()
  def hour_arg(%DateTime{} = weather_time) do
    weather_time
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc """
  Whether a reading for `weather_time` may be stored at database time
  `now`: `:not_yet` before weather_time, `:open` up to and including the
  fetch deadline F, `:closed` after it. Mirrors
  `wallop_landobs_observation_allowed()` exactly.
  """
  @spec window_state(DateTime.t(), DateTime.t()) :: :open | :not_yet | :closed
  def window_state(%DateTime{} = now, %DateTime{} = weather_time) do
    cond do
      DateTime.compare(now, weather_time) == :lt -> :not_yet
      DateTime.compare(now, Schedule.fetch_deadline(weather_time)) != :gt -> :open
      true -> :closed
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: @job_timeout_ms

  @impl Oban.Worker
  def backoff(_job), do: 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"weather_time" => iso}}) when is_binary(iso) do
    case runnable_hour(iso, @client) do
      {:ok, weather_time} -> run(weather_time)
      :error -> {:cancel, :invalid_weather_time}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_weather_time}

  @doc false
  # The hour a job argument names, if the job may run: only the canonical
  # form (`hour_arg/1`), so every job for an hour has the same argument and
  # uniqueness can't be sidestepped by another spelling, and only a whole
  # hour. The whole-hour rule is the real client's: the test client
  # (allowed only in the test environment) fetches the hour at or before
  # any time, which is how tests place "now" in a fetch window.
  @spec runnable_hour(String.t(), module()) :: {:ok, DateTime.t()} | :error
  def runnable_hour(iso, client) when is_binary(iso) do
    with {:ok, wt, 0} <- DateTime.from_iso8601(iso),
         true <- iso == hour_arg(wt),
         true <- client != LandObsClient or whole_hour?(wt) do
      {:ok, wt}
    else
      _ -> :error
    end
  end

  defp whole_hour?(%DateTime{minute: 0, second: 0, microsecond: {0, _}}), do: true
  defp whole_hour?(_), do: false

  defp run(wt) do
    now = DbClock.now()

    cond do
      window_state(now, wt) == :closed ->
        :ok

      DateTime.compare(now, first_poll_at(wt)) == :lt ->
        {:snooze, seconds_until(first_poll_at(wt), now)}

      Observations.pending_draw_ids(wt) == [] ->
        :ok

      true ->
        poll(wt)
    end
  rescue
    e -> poll_failed(wt, :error, e.__struct__)
  catch
    :exit, _ -> poll_failed(wt, :exit, nil)
    :throw, _ -> poll_failed(wt, :throw, nil)
  end

  defp poll(wt) do
    station = Stations.primary()
    result = fetch_one(station.geohash, wt)
    report(wt, station.id, result)

    # The clock is read after fetching, so the decision is as close to the
    # store as it can be. The trigger checks it again on its own clock.
    now = DbClock.now()

    case window_state(now, wt) do
      :open ->
        with {:ok, reading} <- result, do: store(wt, station, reading)
        if Observations.pending_draw_ids(wt) == [], do: :ok, else: next_poll(now, wt)

      :closed ->
        :ok

      :not_yet ->
        {:snooze, seconds_until(first_poll_at(wt), now)}
    end
  end

  # One fetch, capped at @fetch_timeout_ms; a fetch still running then is
  # killed and counts as {:error, :poll_timeout}.
  defp fetch_one(geohash, wt) do
    task = Task.async(fn -> fetch(geohash, wt) end)

    case Task.yield(task, @fetch_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :poll_timeout}
      {:exit, _} -> {:raised, :exit, nil}
    end
  end

  defp fetch(geohash, wt) do
    @client.fetch_hour(geohash, wt)
  rescue
    e -> {:raised, :error, e.__struct__}
  catch
    :exit, _ -> {:raised, :exit, nil}
    :throw, _ -> {:raised, :throw, nil}
  end

  defp report(wt, station_id, {:raised, kind, module} = result) do
    poll_error(wt, kind, module, station_id)
    emit_poll(wt, station_id, result)
  end

  defp report(wt, station_id, result), do: emit_poll(wt, station_id, result)

  defp emit_poll(wt, station_id, result) do
    error =
      case result do
        {:ok, _} -> nil
        {:error, reason} -> reason
        {:raised, kind, _module} -> {:raised, kind}
      end

    :telemetry.execute([:wallop_core, :weather, :poll], %{count: 1}, %{
      station: station_id,
      weather_time: wt,
      ok?: error == nil,
      error: error
    })
  end

  defp store(wt, station, reading) do
    case Observations.store(station.id, reading) do
      {:ok, _} ->
        :telemetry.execute([:wallop_core, :weather, :stored], %{count: 1}, %{
          station: station.id,
          weather_time: wt
        })

      {:error, reason} ->
        # Refused because the hour already has a row: another run stored it
        # first, and that row is the hour's reading. Nothing to report.
        if Observations.for_hour(wt) == nil, do: store_refused(wt, station, reason)
    end
  end

  defp store_refused(wt, station, reason) do
    reason = if reason == :nested_transaction, do: :nested_transaction, else: :refused

    Logger.warning(
      "WeatherObservationWorker: store for #{hour_arg(wt)} from #{station.id} refused (#{reason})"
    )

    :telemetry.execute([:wallop_core, :weather, :store_refused], %{count: 1}, %{
      station: station.id,
      weather_time: wt,
      reason: reason
    })
  end

  # Stops only when the database clock says F has passed. If the database
  # can't be read (it may be what failed), it snoozes: the next run's
  # database-clock check ends the job once F has passed. The BEAM clock is
  # never used.
  defp poll_failed(wt, kind, module) do
    poll_error(wt, kind, module, nil)

    case db_clock() do
      {:ok, now} ->
        if DateTime.compare(now, Schedule.fetch_deadline(wt)) == :gt,
          do: :ok,
          else: {:snooze, Schedule.poll_interval_seconds()}

      :error ->
        {:snooze, Schedule.poll_interval_seconds()}
    end
  end

  defp poll_error(wt, kind, module, station_id) do
    detail = if module, do: " #{inspect(module)}", else: ""
    where = if station_id, do: " from #{station_id}", else: ""

    Logger.error(
      "WeatherObservationWorker: poll for #{hour_arg(wt)}#{where} failed (#{kind}#{detail})"
    )

    :telemetry.execute([:wallop_core, :weather, :poll_error], %{count: 1}, %{
      weather_time: wt,
      station: station_id,
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

  defp first_poll_at(wt), do: DateTime.add(wt, Schedule.first_poll_after_weather_time_seconds())

  @doc false
  # The next poll, at least @deadline_margin_seconds before F; when there is
  # no whole second left for that, polling stops.
  @spec next_poll(DateTime.t(), DateTime.t()) :: {:snooze, pos_integer()} | :ok
  def next_poll(now, wt) do
    left = DateTime.diff(Schedule.fetch_deadline(wt), now) - @deadline_margin_seconds
    if left >= 1, do: {:snooze, min(Schedule.poll_interval_seconds(), left)}, else: :ok
  end

  defp seconds_until(t, now), do: max(DateTime.diff(t, now), 1)
end
