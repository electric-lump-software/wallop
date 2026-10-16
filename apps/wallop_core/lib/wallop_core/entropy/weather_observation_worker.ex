defmodule WallopCore.Entropy.WeatherObservationWorker do
  @moduledoc """
  Fetches the Land Observations reading for one observation hour and stores
  it once for that hour, for every observation-weather draw waiting on it.

  One job per hour (unique on `weather_time`), however many draws lock for
  it. Build it with `new_for_hour/1`, which writes the hour in one canonical
  form and schedules the first poll for weather_time + 5 min.

  Each run polls both stations (the backup too, so its latency is measured)
  and then reads the database clock. That clock alone decides what may be
  stored, by `station_for/2`: the primary from weather_time to the backup
  cutover (F - 10 min), the backup after the cutover up to the fetch deadline
  F, and nothing after F. These are the windows the store's insert trigger
  enforces, so this worker has no choice to make. A run past F stops without
  storing.

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

  Telemetry:

    * `[:wallop_core, :weather, :poll]`, `%{count: 1}`,
      `%{station, ok?, error}`: one per station per poll;
    * `[:wallop_core, :weather, :stored]`, `%{count: 1}`,
      `%{station, weather_time}`: the hour's reading was stored by this run;
    * `[:wallop_core, :weather, :store_refused]`, `%{count: 1}`,
      `%{station, weather_time, reason}`: a store was refused and the hour
      still has no row (`reason` is `:nested_transaction` or `:refused`);
    * `[:wallop_core, :weather, :poll_error]`, `%{count: 1}`,
      `%{weather_time, kind}`: a fetch or the run raised (`:error`), exited
      (`:exit`) or threw (`:throw`).
  """
  use Oban.Worker,
    queue: :weather,
    # Snoozes don't count against this; only crashes and timeouts do.
    max_attempts: 100,
    unique: [period: :infinity, keys: [:weather_time]]

  require Logger

  alias WallopCore.Entropy.LandObsClient
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  # Tests swap in a wrapper around the real client; see
  # WallopCore.Test.WindowedLandObsClient. Fixed at compile time.
  @client Application.compile_env(:wallop_core, [__MODULE__, :land_obs_client], LandObsClient)

  # The client's own timeouts are per chunk (connect 5 s, receive 10 s), so
  # each fetch is also capped here; both stations are fetched at once.
  # Fetch cap + store (5 s statement timeout) + reads stay under the job
  # timeout, and the job timeout stays under the poll interval.
  @fetch_timeout_ms 20_000
  @job_timeout_ms 30_000
  # The last poll is made at least this long before F.
  @deadline_margin_seconds 5

  @doc "The job for observation hour `weather_time`."
  @spec new_for_hour(DateTime.t()) :: Ecto.Changeset.t()
  def new_for_hour(%DateTime{} = weather_time) do
    new(%{weather_time: hour_arg(weather_time)},
      scheduled_at: first_poll_at(weather_time)
    )
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
  What may be stored for `weather_time` at database time `now`: the window's
  station, `:not_yet` before weather_time, or `:closed` after the fetch
  deadline. Mirrors `wallop_landobs_observation_allowed()` exactly.
  """
  @spec station_for(DateTime.t(), DateTime.t()) ::
          {:ok, Stations.station()} | :not_yet | :closed
  def station_for(%DateTime{} = now, %DateTime{} = weather_time) do
    cond do
      DateTime.compare(now, weather_time) == :lt ->
        :not_yet

      DateTime.compare(now, Schedule.backup_cutover(weather_time)) != :gt ->
        {:ok, Stations.primary()}

      DateTime.compare(now, Schedule.fetch_deadline(weather_time)) != :gt ->
        {:ok, Stations.backup()}

      true ->
        :closed
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: @job_timeout_ms

  @impl Oban.Worker
  def backoff(_job), do: 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"weather_time" => iso}}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, weather_time, 0} -> run(weather_time)
      _ -> {:cancel, :invalid_weather_time}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_weather_time}

  defp run(wt) do
    now = Observations.db_now()

    cond do
      station_for(now, wt) == :closed ->
        :ok

      DateTime.compare(now, first_poll_at(wt)) == :lt ->
        {:snooze, seconds_until(first_poll_at(wt), now)}

      Observations.pending_v6_draw_ids(wt) == [] ->
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
    results = fetch_all(wt)
    Enum.each(results, fn {station_id, result} -> report(wt, station_id, result) end)

    # The clock is read after fetching, so the decision is as close to the
    # store as it can be. The trigger checks it again on its own clock.
    now = Observations.db_now()

    case station_for(now, wt) do
      {:ok, station} ->
        with {:ok, reading} <- result_for(results, station) do
          store(wt, station, reading)
        end

        if Observations.pending_v6_draw_ids(wt) == [],
          do: :ok,
          else: {:snooze, next_poll_in(now, wt)}

      :closed ->
        :ok

      :not_yet ->
        {:snooze, seconds_until(first_poll_at(wt), now)}
    end
  end

  defp fetch_all(wt) do
    stations = Stations.all()
    tasks = Enum.map(stations, fn s -> Task.async(fn -> fetch_one(s.geohash, wt) end) end)
    yields = Task.yield_many(tasks, timeout: @fetch_timeout_ms, on_timeout: :kill_task)

    Enum.zip_with(stations, yields, fn station, {_task, outcome} ->
      result =
        case outcome do
          {:ok, result} -> result
          nil -> {:error, :poll_timeout}
          {:exit, _} -> {:raised, :exit, nil}
        end

      {station.id, result}
    end)
  end

  defp fetch_one(geohash, wt) do
    @client.fetch_hour(geohash, wt)
  rescue
    e -> {:raised, :error, e.__struct__}
  catch
    :exit, _ -> {:raised, :exit, nil}
    :throw, _ -> {:raised, :throw, nil}
  end

  defp result_for(results, station) do
    {_, result} = List.keyfind(results, station.id, 0)
    result
  end

  defp report(wt, _station_id, {:raised, kind, module}), do: poll_error(wt, kind, module)

  defp report(_wt, station_id, result) do
    error =
      case result do
        {:ok, _} -> nil
        {:error, reason} -> reason
      end

    :telemetry.execute([:wallop_core, :weather, :poll], %{count: 1}, %{
      station: station_id,
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

  defp poll_failed(wt, kind, module) do
    poll_error(wt, kind, module)

    if DateTime.compare(clock_after_failure(), Schedule.fetch_deadline(wt)) == :gt,
      do: :ok,
      else: {:snooze, Schedule.poll_interval_seconds()}
  end

  defp poll_error(wt, kind, module) do
    detail = if module, do: " #{inspect(module)}", else: ""

    Logger.error("WeatherObservationWorker: poll for #{hour_arg(wt)} failed (#{kind}#{detail})")

    :telemetry.execute([:wallop_core, :weather, :poll_error], %{count: 1}, %{
      weather_time: wt,
      kind: kind
    })
  end

  # Only decides whether to keep polling after a failure (the database may
  # be what failed). What may be stored is decided on the database clock.
  defp clock_after_failure do
    Observations.db_now()
  rescue
    _ -> DateTime.utc_now()
  catch
    :exit, _ -> DateTime.utc_now()
  end

  defp first_poll_at(wt), do: DateTime.add(wt, Schedule.first_poll_after_weather_time_seconds())

  defp next_poll_in(now, wt) do
    left = DateTime.diff(Schedule.fetch_deadline(wt), now) - @deadline_margin_seconds
    max(min(Schedule.poll_interval_seconds(), left), 1)
  end

  defp seconds_until(t, now), do: max(DateTime.diff(t, now), 1)
end
