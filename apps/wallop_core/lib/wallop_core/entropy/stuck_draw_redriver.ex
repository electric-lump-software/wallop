defmodule WallopCore.Entropy.StuckDrawRedriver do
  @moduledoc """
  Puts back the job of any locked draw that has lost it, so no draw sticks.
  Run every ten minutes by wallop's own Oban cron.

  ## Execution jobs

  A draw is stuck when it is still `awaiting_entropy` or `pending_entropy`
  15 minutes after it was due, on the database clock, and no live job
  (available, scheduled, executing, retryable or suspended) exists for it
  under either execution worker. It was due at:

    * an observation-weather draw: its drand round's publication time,
      from `WallopCore.Entropy.V6Rules.drand_pub_time/2`;
    * a forecast draw: its `weather_time`.

  A stuck observation-weather draw gets `ObservationDrawWorker` back. A
  draw whose `ObservationDrawWorker` job was cancelled is skipped: a
  cancelled job is how the executor refuses a draw, and the cancelled row
  is the record of that refusal. Once the row is pruned, the draw is
  re-driven once more. Re-running a refused draw after a fix is a manual
  re-insert.

  Forecast draws are re-driven (with `EntropyWorker`) only when
  `config :wallop_core, :redrive_forecast_draws, true`. It is off by
  default: a forecast draw that has sat stuck for days would otherwise run
  on the first deploy, late and possibly on drand alone. With it off, no
  forecast draw is even read.

  ## Fetch jobs

  For each hour with pending observation-weather draws and no stored
  reading, while the database clock is before the hour's fetch deadline
  (`WallopCore.Entropy.V6Rules.fetch_deadline/2`), the hour's fetch job is
  inserted again. It is unique among live jobs, so an hour whose job is
  still alive is untouched.

  ## What it never does

  It changes no draw, chooses nothing and fails nothing. A re-inserted job
  reads the stored state exactly as the original would have, under the same
  database guards. Running it twice inserts nothing the second time: the
  live-job check comes first, and each worker's uniqueness makes a race
  with another inserter harmless.

  Each insert emits `[:wallop_core, :redrive, :reinserted]` with
  `%{count: 1}` and metadata `%{kind: :execution | :fetch, protocol:
  :observation | :forecast}`, plus `draw_id` or `weather_time`, and logs a
  warning. A draw re-driven again and again is a fault worth an alert.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias WallopCore.Entropy.{
    EntropyWorker,
    ObservationDrawWorker,
    V6Rules,
    WeatherObservationWorker
  }

  alias WallopCore.Log
  alias WallopCore.Repo
  alias WallopCore.Weather.Observations

  @threshold_seconds 15 * 60

  # Oban's :incomplete group: every state in which a job may still run.
  @live_states ~w(available scheduled executing retryable suspended)
  @workers [inspect(ObservationDrawWorker), inspect(EntropyWorker)]

  # Locked draws without a live execution job. An observation-weather draw
  # (either half of the pair set) is left out once its ObservationDrawWorker
  # job has been cancelled. Forecast draws (pair NULL) are read only when $1.
  @stuck_sql """
  SELECT d.id::text, d.lock_schema_version, d.entropy_composition, d.drand_round, d.weather_time
  FROM draws d
  WHERE d.status IN ('awaiting_entropy', 'pending_entropy')
    AND ((d.lock_schema_version IS NOT NULL OR d.entropy_composition IS NOT NULL) OR $1)
    AND NOT EXISTS (
      SELECT 1 FROM oban_jobs j
      WHERE j.state::text = ANY($2)
        AND j.worker = ANY($3)
        AND j.args->>'draw_id' = d.id::text
    )
    AND NOT (
      (d.lock_schema_version IS NOT NULL OR d.entropy_composition IS NOT NULL)
      AND EXISTS (
        SELECT 1 FROM oban_jobs j
        WHERE j.state::text = 'cancelled'
          AND j.worker = $4
          AND j.args->>'draw_id' = d.id::text
      )
    )
  """

  @pending_v6_sql """
  SELECT d.id::text, d.lock_schema_version, d.entropy_composition, d.drand_round, d.weather_time
  FROM draws d
  WHERE d.status IN ('awaiting_entropy', 'pending_entropy')
    AND (d.lock_schema_version IS NOT NULL OR d.entropy_composition IS NOT NULL)
  """

  @impl Oban.Worker
  def perform(_job) do
    _ = redrive()
    :ok
  end

  @doc """
  Re-inserts the execution job of every stuck draw and the fetch job of
  every open hour that has lost it. Returns the ids of the draws whose
  execution job it inserted.
  """
  @spec redrive() :: [String.t()]
  def redrive do
    now = Observations.db_now()
    redriven = redrive_executions(now)
    redrive_fetches(now)
    redriven
  end

  @doc "Whether forecast draws are re-driven. Off unless configured."
  @spec forecast_enabled?() :: boolean()
  def forecast_enabled?,
    do: Application.get_env(:wallop_core, :redrive_forecast_draws, false) == true

  defp redrive_executions(now) do
    %{rows: rows} =
      Repo.query!(@stuck_sql, [
        forecast_enabled?(),
        @live_states,
        @workers,
        inspect(ObservationDrawWorker)
      ])

    for row <- rows,
        draw <- [to_draw(row)],
        {:ok, protocol, due} <- [due_time(draw)],
        due_passed?(due, now),
        inserted?(insert_execution(protocol, draw.id)) do
      reinserted(:execution, protocol, %{draw_id: draw.id}, "draw #{Log.redact_id(draw.id)}")
      draw.id
    end
  end

  defp redrive_fetches(now) do
    %{rows: rows} = Repo.query!(@pending_v6_sql, [])

    hours =
      for row <- rows,
          draw <- [to_draw(row)],
          {:ok, rules} <- [V6Rules.rules(draw)],
          before?(now, V6Rules.fetch_deadline(rules, draw)),
          uniq: true,
          do: {rules, draw.weather_time}

    Enum.each(hours, fn {rules, wt} ->
      if Observations.pending_v6_draw_ids(wt) != [] and inserted?(insert_fetch(rules, wt)) do
        reinserted(
          :fetch,
          :observation,
          %{weather_time: wt},
          "hour #{DateTime.to_iso8601(wt)}"
        )
      end
    end)
  end

  defp to_draw([id, schema, tag, round, wt]) do
    %{
      id: id,
      lock_schema_version: schema,
      entropy_composition: tag,
      drand_round: round,
      weather_time: wt && DateTime.from_naive!(wt, "Etc/UTC")
    }
  end

  # When the draw was due: pub(R) by its rules for an observation-weather
  # draw, weather_time for a forecast draw.
  defp due_time(%{lock_schema_version: nil, entropy_composition: nil} = draw),
    do: {:ok, :forecast, draw.weather_time}

  defp due_time(draw) do
    case V6Rules.rules(draw) do
      {:ok, rules} ->
        {:ok, :observation, V6Rules.drand_pub_time(rules, draw)}

      :error ->
        # Refused at insert by the draws guard, so it can't exist; if one
        # did, no rules say when it was due, and its job would refuse it.
        Logger.warning(
          "StuckDrawRedriver: draw #{Log.redact_id(draw.id)} has an unknown stored pair; not re-driven"
        )

        :error
    end
  end

  defp due_passed?(nil, _now), do: false
  defp due_passed?(due, now), do: before?(DateTime.add(due, @threshold_seconds), now)

  defp before?(a, b), do: DateTime.compare(a, b) == :lt

  # The live-job check above already ran. Each worker is unique on draw_id
  # among live jobs, so a race with another inserter is a conflict, not a
  # second job. EntropyWorker's own uniqueness also counts completed jobs,
  # so the re-drive narrows it to live ones, as ObservationDrawWorker has.
  defp insert_execution(:observation, id),
    do: Oban.insert(ObservationDrawWorker.new(%{draw_id: id}))

  defp insert_execution(:forecast, id),
    do:
      Oban.insert(
        EntropyWorker.new(%{draw_id: id},
          unique: [period: :infinity, keys: [:draw_id], states: :incomplete]
        )
      )

  # One clause per observation tag: nothing falls through to Land Obs.
  defp insert_fetch(:landobs, wt) do
    case wt do
      %DateTime{minute: 0, second: 0, microsecond: {0, _}} ->
        Oban.insert(WeatherObservationWorker.new_for_hour(wt))

      _ ->
        # The lock requires a whole hour, so this can't be stored.
        Logger.warning(
          "StuckDrawRedriver: weather_time #{DateTime.to_iso8601(wt)} is not a whole hour"
        )

        :error
    end
  end

  defp inserted?({:ok, %Oban.Job{conflict?: false}}), do: true
  defp inserted?(_), do: false

  defp reinserted(kind, protocol, meta, what) do
    Logger.warning("StuckDrawRedriver: re-inserted the #{kind} job for #{what}")

    :telemetry.execute(
      [:wallop_core, :redrive, :reinserted],
      %{count: 1},
      Map.merge(%{kind: kind, protocol: protocol}, meta)
    )
  end
end
