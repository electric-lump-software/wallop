defmodule WallopCore.Entropy.StuckDrawRedriver do
  @moduledoc """
  Puts back the job of any locked draw that has lost it, so no draw sticks.
  Run every ten minutes by wallop's own Oban cron.

  ## Execution jobs

  A draw is stuck when it is a lock schema 6 draw (observation weather or
  grid frequency), still `awaiting_entropy` or `pending_entropy` 15 minutes
  after it was due, on the database clock, and no job that can still run
  it exists. It was due at its drand round's publication time, from
  `WallopCore.Entropy.V6Rules.drand_pub_time/2`. Only draws with
  `lock_schema_version = '6'` are read: a retired forecast draw, which has
  none, is never re-driven or reported.

  A live job counts only when it can still run the draw soon, so that a job
  moved out of reach by one row write (scheduled for 2099, say) can't stop
  a draw silently after its outcome is knowable. It counts when it is on
  its worker's own queue and either executing (Lifeline rescues a stale
  one) or available, scheduled or retryable with attempts left and
  `scheduled_at` at most D after now, on the database clock. D is
  `ObservationDrawWorker`'s longest delay, its 120 s backoff cap
  (`ObservationDrawWorker.max_delay_seconds/0`). A suspended job never
  counts: nothing in wallop resumes one.

  Why that bound: every job the worker schedules itself is inside it. Its
  first run is pub(R) + 5 s, its snoozes end by pub(R) + 1 s or a few
  seconds after F or pub(R), and each retry is at most D after the failed
  attempt, so a waiting job is never due more than D from now. The
  re-drive acts only on draws past pub(R) + 15 minutes, so the bound is
  never tighter than pub(R) + 15 minutes + D; it is measured from now
  rather than from pub(R) so that a job inserted late (by the re-drive
  itself, or by hand) or still retrying through a long drand outage is
  never mistaken for a parked one.

  A stuck draw, of either tag, gets `ObservationDrawWorker` back.
  Its live jobs that can't run it (parked) are cancelled first, in the same
  transaction, with the reason recorded in the job's `errors` and
  `meta.redrive_replaced` set; otherwise the new job would conflict with
  them on uniqueness. Cancelling, not deleting, keeps the parked row as
  evidence.

  A draw whose `ObservationDrawWorker` job was cancelled is skipped: a
  cancelled job is how the executor refuses a draw, and the cancelled row
  is the record of that refusal. Any cancelled `ObservationDrawWorker` row
  for the draw parks it, whatever cancelled it, including one cancelled by
  hand with `Oban.cancel_job/1`, except the rows this module cancelled
  itself (`meta.redrive_replaced`). Once the row is pruned, the draw is
  re-driven once more. Re-running a refused draw after a fix is a manual
  re-insert.

  ## Overdue draws

  Every run also emits `[:wallop_core, :v6, :overdue]`, `%{count: 1}`,
  `%{draw_id, protocol, since}` (`since` is pub(R) + 15 minutes), for each
  schema 6 draw past pub(R) + 15 minutes that is still `awaiting_entropy`
  or `pending_entropy` and was not refused by the executor, whatever its
  jobs say, every run until it completes. A refusal counts only when a
  cancelled `ObservationDrawWorker` row carries the executor's own
  refusal (`{:cancel, "execution refused: ..."}`, which Oban records in the
  row's `errors`; the executor also emitted `exec_refused` then). A row
  cancelled by hand, inserted already cancelled or cancelled by this module
  carries none, so its draw is still reported. Re-driven draws are reported
  too: a re-drive is not a result.

  ## Fetch jobs

  For each Land Observations hour with pending draws and no stored reading,
  while the database clock is before the hour's fetch deadline F
  (`WallopCore.Entropy.V6Rules.fetch_deadline/2`), the hour's fetch job is
  inserted again. It is unique among live jobs, so an hour whose job is
  still alive is untouched.

  Grid-frequency windows are not re-driven. A window is open for at most
  W_freq (240 s), shorter than the ten-minute cron, so a re-drive would
  rarely land inside it. A lost window job instead leaves T's draws to fall
  back by rule (`no_frequency_by_deadline`, decided by the database from
  stored state): nothing is chosen and no draw fails. The wallop-app
  monitor alerts on every fallback, so a lost job is seen.

  ## What it never does

  It changes no draw, chooses nothing and fails nothing. A re-inserted job
  reads the stored state exactly as the original would have, under the same
  database guards. Running it twice inserts nothing the second time: the
  live-job check comes first, and each worker's uniqueness makes a race
  with another inserter harmless.

  Each insert emits `[:wallop_core, :redrive, :reinserted]` with
  `%{count: 1}` and metadata `%{kind: :execution | :fetch, protocol:
  :observation | :frequency}`, plus `draw_id` or
  `weather_time` (and `replaced`, the number of parked jobs cancelled, for
  a schema 6 execution), and logs a warning. A draw re-driven again and
  again is a fault worth an alert.

  Job timeout 60 s: a handful of database queries and job inserts. A run
  cut short changes nothing it has not committed, and the next run ten
  minutes later picks up the rest.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias WallopCore.DbClock
  alias WallopCore.Entropy.{ObservationDrawWorker, V6Rules, WeatherObservationWorker}
  alias WallopCore.Log
  alias WallopCore.Repo
  alias WallopCore.Weather.Observations

  @threshold_seconds 15 * 60

  @live_states ~w(available scheduled executing retryable suspended)

  @runnable_v6_job """
  j.queue = $3
  AND (j.state::text = 'executing'
       OR (j.state::text IN ('available', 'scheduled', 'retryable')
           AND j.attempt < j.max_attempts
           AND j.scheduled_at <= timezone('UTC', now()) + make_interval(secs => $4)))
  """

  @parked_by_cancel """
  EXISTS (
    SELECT 1 FROM oban_jobs c
    WHERE c.state::text = 'cancelled'
      AND c.worker = $2
      AND c.args @> jsonb_build_object('draw_id', d.id::text)
      AND NOT (c.meta @> '{"redrive_replaced": true}'::jsonb)
  )
  """

  @stuck_sql """
  SELECT d.id::text, d.lock_schema_version, d.entropy_composition, d.drand_round, d.weather_time,
    d.freq_start
  FROM draws d
  WHERE d.status IN ('awaiting_entropy', 'pending_entropy')
    AND d.lock_schema_version = '6'
    AND NOT EXISTS (
      SELECT 1 FROM oban_jobs j
      WHERE j.state::text = ANY($1)
        AND j.worker = $2
        AND j.args @> jsonb_build_object('draw_id', d.id::text)
        AND (#{@runnable_v6_job})
    )
    AND NOT #{@parked_by_cancel}
  """

  @cancel_parked_sql """
  UPDATE oban_jobs j
  SET state = 'cancelled',
      cancelled_at = timezone('UTC', now()),
      meta = j.meta || '{"redrive_replaced": true}'::jsonb,
      errors = array_append(j.errors, jsonb_build_object(
        'attempt', j.attempt,
        'at', timezone('UTC', now()),
        'error', 'replaced by the re-drive: this job could not run its draw in time'))
  FROM draws d
  WHERE d.id = $5::uuid
    AND j.worker = $2
    AND j.state::text = ANY($1)
    AND j.state::text <> 'executing'
    AND j.args @> jsonb_build_object('draw_id', d.id::text)
    AND NOT (#{@runnable_v6_job})
  RETURNING j.id
  """

  @pending_v6_sql """
  SELECT d.id::text, d.lock_schema_version, d.entropy_composition, d.drand_round, d.weather_time,
    d.freq_start
  FROM draws d
  WHERE d.status IN ('awaiting_entropy', 'pending_entropy')
    AND d.lock_schema_version = '6'
  """

  @unrefused_v6_sql """
  SELECT d.id::text, d.lock_schema_version, d.entropy_composition, d.drand_round, d.weather_time,
    d.freq_start
  FROM draws d
  WHERE d.status IN ('awaiting_entropy', 'pending_entropy')
    AND d.lock_schema_version = '6'
    AND NOT EXISTS (
      SELECT 1 FROM oban_jobs c, unnest(c.errors) e
      WHERE c.state::text = 'cancelled'
        AND c.worker = $1
        AND c.args @> jsonb_build_object('draw_id', d.id::text)
        AND e->>'error' LIKE $2
    )
  """

  @refusal_pattern "%#{inspect(ObservationDrawWorker)} failed with " <>
                     ~s({:cancel, "execution refused: %)

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

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
    now = DbClock.now()
    redriven = redrive_executions(now)
    redrive_fetches(now)
    report_overdue(now)
    redriven
  end

  defp redrive_executions(now) do
    %{rows: rows} = Repo.query!(@stuck_sql, job_params())

    for row <- rows,
        draw <- [to_draw(row)],
        {:ok, protocol, due} <- [due_time(draw)],
        due_passed?(due, now),
        {:ok, meta} <- [redrive_execution(protocol, draw.id)] do
      reinserted(:execution, protocol, meta, "draw #{Log.redact_id(draw.id)}")
      draw.id
    end
  end

  defp job_params do
    [
      @live_states,
      inspect(ObservationDrawWorker),
      queue_of(ObservationDrawWorker),
      ObservationDrawWorker.max_delay_seconds()
    ]
  end

  defp queue_of(worker), do: worker.__opts__() |> Keyword.fetch!(:queue) |> to_string()

  defp redrive_execution(protocol, id) do
    Repo.transaction(fn ->
      %{rows: cancelled} = Repo.query!(@cancel_parked_sql, job_params() ++ [Ecto.UUID.dump!(id)])

      if inserted?(insert_execution(protocol, id)),
        do: replaced(id, length(cancelled)),
        else: Repo.rollback(:not_inserted)
    end)
  end

  defp replaced(id, 0), do: %{draw_id: id, replaced: 0}

  defp replaced(id, n) do
    Logger.warning(
      "StuckDrawRedriver: cancelled #{n} parked job(s) for draw #{Log.redact_id(id)}"
    )

    %{draw_id: id, replaced: n}
  end

  defp report_overdue(now) do
    %{rows: rows} =
      Repo.query!(@unrefused_v6_sql, [inspect(ObservationDrawWorker), @refusal_pattern])

    for row <- rows,
        draw <- [to_draw(row)],
        {:ok, protocol, due} <- [due_time(draw)],
        due_passed?(due, now) do
      since = DateTime.add(due, @threshold_seconds)

      Logger.warning(
        "StuckDrawRedriver: draw #{Log.redact_id(draw.id)} is overdue since " <>
          DateTime.to_iso8601(since)
      )

      :telemetry.execute([:wallop_core, :v6, :overdue], %{count: 1}, %{
        draw_id: draw.id,
        protocol: protocol,
        since: since
      })
    end

    :ok
  end

  defp redrive_fetches(now) do
    %{rows: rows} = Repo.query!(@pending_v6_sql, [])

    hours =
      for row <- rows,
          draw <- [to_draw(row)],
          {:ok, :landobs} <- [V6Rules.rules(draw)],
          before?(now, V6Rules.fetch_deadline(:landobs, draw)),
          uniq: true,
          do: {:landobs, draw.weather_time}

    Enum.each(hours, fn {rules, wt} ->
      if Observations.pending_draw_ids(wt) != [] and inserted?(insert_fetch(rules, wt)) do
        reinserted(
          :fetch,
          :observation,
          %{weather_time: wt},
          "hour #{DateTime.to_iso8601(wt)}"
        )
      end
    end)
  end

  defp to_draw([id, schema, tag, round, wt, t]) do
    %{
      id: id,
      lock_schema_version: schema,
      entropy_composition: tag,
      drand_round: round,
      weather_time: wt && DateTime.from_naive!(wt, "Etc/UTC"),
      freq_start: t && DateTime.from_naive!(t, "Etc/UTC")
    }
  end

  defp due_time(draw) do
    case V6Rules.rules(draw) do
      {:ok, rules} ->
        {:ok, protocol(rules), V6Rules.drand_pub_time(rules, draw)}

      :error ->
        Logger.warning(
          "StuckDrawRedriver: draw #{Log.redact_id(draw.id)} has an unknown stored pair; not re-driven"
        )

        :error
    end
  end

  defp due_passed?(nil, _now), do: false
  defp due_passed?(due, now), do: before?(DateTime.add(due, @threshold_seconds), now)

  defp before?(a, b), do: DateTime.compare(a, b) == :lt

  defp protocol(:landobs), do: :observation
  defp protocol(:freq), do: :frequency

  defp insert_execution(protocol, id) when protocol in [:observation, :frequency],
    do: Oban.insert(ObservationDrawWorker.new(%{draw_id: id}))

  defp insert_fetch(:landobs, wt) do
    case wt do
      %DateTime{minute: 0, second: 0, microsecond: {0, _}} ->
        Oban.insert(WeatherObservationWorker.new_for_hour(wt))

      _ ->
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
