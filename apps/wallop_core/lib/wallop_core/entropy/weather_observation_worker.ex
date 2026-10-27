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

  Each call is first reserved against the daily cap
  (`WallopCore.Weather.LandObsBudget`, `LAND_OBS_DAILY_CAP`). At the cap no
  call is made: the poll fails with `:daily_cap` like any other error, and
  the job snoozes past F, so the hour's draws reach their deadline without
  a reading and complete by the fallback rule. The first refusal of a UTC
  day is logged as an error.

  A run inside a database transaction makes no reservation and no call
  (`{:error, :nested_transaction}`): a fetch must never hold a connection,
  or anything else, open across HTTP.

  A failed poll is logged at warning, with its reason passed through
  `WallopCore.Entropy.PollLog`. Logs and telemetry carry only enumerated
  terms (the client's error terms, exception module names), never response
  bodies, request structs or the API key.

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
      (`:throw`);
    * `[:wallop_core, :weather, :cap_reached]`, `%{count: 1}`,
      `%{weather_time, cap}`: a call was refused at the daily cap (one event
      per refused call).
  """
  use Oban.Worker,
    queue: :weather,
    max_attempts: 100,
    unique: [period: :infinity, keys: [:weather_time], states: :incomplete]

  require Logger

  alias WallopCore.DbClock
  alias WallopCore.Entropy.{LandObsClient, PollLog}
  alias WallopCore.Repo
  alias WallopCore.Weather.{LandObsBudget, Observations, Schedule, Stations}

  @client Application.compile_env(:wallop_core, [__MODULE__, :land_obs_client], LandObsClient)

  if @client != LandObsClient and Mix.env() != :test do
    raise CompileError,
      description:
        "#{inspect(__MODULE__)}: :land_obs_client may be set only in the test " <>
          "environment (got #{inspect(@client)} in #{Mix.env()}). Outside tests the " <>
          "worker always uses #{inspect(LandObsClient)}."
  end

  @fetch_timeout_ms 20_000
  @job_timeout_ms 30_000
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

    now = DbClock.now()

    case window_state(now, wt) do
      :open ->
        with {:ok, reading} <- result, do: store(wt, station, reading)

        cond do
          Observations.pending_draw_ids(wt) == [] -> :ok
          result == {:error, :daily_cap} -> {:snooze, past_deadline(now, wt)}
          true -> next_poll(now, wt)
        end

      :closed ->
        :ok

      :not_yet ->
        {:snooze, seconds_until(first_poll_at(wt), now)}
    end
  end

  defp fetch_one(geohash, wt) do
    if Repo.in_transaction?() do
      {:error, :nested_transaction}
    else
      with :ok <- reserve(wt), do: timed_fetch(geohash, wt)
    end
  end

  defp reserve(wt) do
    case LandObsBudget.reserve() do
      {:ok, _calls} ->
        :ok

      {:error, :daily_cap, _calls} ->
        cap_reached(wt)
        {:error, :daily_cap}
    end
  end

  defp cap_reached(wt) do
    cap = LandObsBudget.cap()

    if LandObsBudget.claim_cap_report() do
      Logger.error(
        "WeatherObservationWorker: daily cap of #{cap} Land Observations calls reached; " <>
          "no more calls until 00:00 UTC"
      )
    end

    :telemetry.execute([:wallop_core, :weather, :cap_reached], %{count: 1}, %{
      weather_time: wt,
      cap: cap
    })
  end

  defp timed_fetch(geohash, wt) do
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

    with {:error, reason} <- result do
      Logger.warning(
        "WeatherObservationWorker: poll for #{hour_arg(wt)} from #{station_id} failed " <>
          "(#{inspect(PollLog.term(reason))})"
      )
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

  defp past_deadline(now, wt),
    do: max(DateTime.diff(Schedule.fetch_deadline(wt), now), 0) + 1

  defp first_poll_at(wt), do: DateTime.add(wt, Schedule.first_poll_after_weather_time_seconds())

  @doc false
  @spec next_poll(DateTime.t(), DateTime.t()) :: {:snooze, pos_integer()} | :ok
  def next_poll(now, wt) do
    left = DateTime.diff(Schedule.fetch_deadline(wt), now) - @deadline_margin_seconds
    if left >= 1, do: {:snooze, min(Schedule.poll_interval_seconds(), left)}, else: :ok
  end

  defp seconds_until(t, now), do: max(DateTime.diff(t, now), 1)
end
