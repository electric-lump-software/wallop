defmodule WallopCore.Entropy.StuckDrawRedriverTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  @moduletag :capture_log

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, ObservationDrawWorker, StuckDrawRedriver}
  alias WallopCore.Entropy.{FrequencyWindowWorker, WeatherObservationWorker}
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  @live_states ~w(available scheduled executing retryable suspended)
  @runnable_v6_states ~w(available scheduled executing retryable)
  @event [:wallop_core, :redrive, :reinserted]
  @forecast_worker "WallopCore.Entropy.EntropyWorker"

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  defp delete_jobs_for!(id),
    do: Repo.query!("DELETE FROM oban_jobs WHERE args->>'draw_id' = $1", [id])

  defp jobs_for(worker, id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT state FROM oban_jobs WHERE worker = $1 AND args->>'draw_id' = $2",
        [worker_name(worker), id]
      )

    List.flatten(rows)
  end

  defp worker_name(worker) when is_binary(worker), do: worker
  defp worker_name(worker), do: inspect(worker)

  defp put_job!(worker, id, state) when is_binary(worker) do
    Repo.query!(
      """
      INSERT INTO oban_jobs (state, queue, worker, args, max_attempts, scheduled_at, inserted_at)
      VALUES ($1::oban_job_state, 'entropy', $2, $3, 10, timezone('UTC', now()),
        timezone('UTC', now()))
      """,
      [state, worker, %{"draw_id" => id}]
    )
  end

  defp put_job!(worker, id, state) do
    {:ok, job} = Oban.insert(worker.new(%{draw_id: id}))
    Repo.query!("UPDATE oban_jobs SET state = $2 WHERE id = $1", [job.id, state])
    job
  end

  defp stuck_v6(pub_offset) do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.truncate(:second)
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(pub_offset))
    delete_jobs_for!(draw.id)
    draw
  end

  defp stuck_forecast(status, weather_offset) do
    draw = put_retired_forecast_draw!(create_api_key(), status)
    wt = DateTime.add(DateTime.utc_now(), weather_offset)

    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET weather_time = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        DateTime.to_naive(wt)
      ])
    end)

    Ash.get!(Draw, draw.id, authorize?: false)
  end

  defp set_status!(draw, status) do
    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET status = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        status
      ])
    end)
  end

  describe "observation-weather draws" do
    test "past pub(R) + 15m with no job: the execution job comes back, reported" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      draw = stuck_v6(-20 * 60)

      assert draw.id in StuckDrawRedriver.redrive()
      assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})

      id = draw.id

      assert_receive {@event, ^ref, %{count: 1},
                      %{kind: :execution, protocol: :observation, draw_id: ^id}}
    end

    test "discarded and completed jobs count as gone" do
      for state <- ~w(discarded completed) do
        draw = stuck_v6(-20 * 60)
        put_job!(ObservationDrawWorker, draw.id, state)

        assert draw.id in StuckDrawRedriver.redrive(), state

        assert Enum.sort(jobs_for(ObservationDrawWorker, draw.id)) ==
                 Enum.sort(["available", state])
      end
    end

    test "a cancelled job is the refusal marker: skipped, then re-driven once after it is pruned" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      draw = stuck_v6(-20 * 60)
      cancelled = put_job!(ObservationDrawWorker, draw.id, "cancelled")

      refute draw.id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, draw.id) == ["cancelled"]
      refute_received {@event, ^ref, _, %{draw_id: _}}

      Repo.query!("DELETE FROM oban_jobs WHERE id = $1", [cancelled.id])
      assert draw.id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, draw.id) == ["available"]
    end

    test "a runnable job, in any runnable state, means the draw is left alone" do
      for state <- @runnable_v6_states do
        draw = stuck_v6(-20 * 60)
        put_job!(ObservationDrawWorker, draw.id, state)

        refute draw.id in StuckDrawRedriver.redrive(), state
        assert jobs_for(ObservationDrawWorker, draw.id) == [state]
      end
    end

    test "a live job of the retired forecast worker doesn't count: the draw is re-driven" do
      for state <- @live_states do
        draw = stuck_v6(-20 * 60)
        put_job!(@forecast_worker, draw.id, state)

        assert draw.id in StuckDrawRedriver.redrive(), state
        assert jobs_for(ObservationDrawWorker, draw.id) == ["available"]
        assert jobs_for(@forecast_worker, draw.id) == [state]
      end
    end

    test "not yet past the threshold, and terminal draws, are left alone" do
      recent = stuck_v6(-5 * 60)
      ahead = stuck_v6(10 * 60)

      terminal =
        for status <- ~w(completed failed expired) do
          draw = stuck_v6(-20 * 60)
          set_status!(draw, status)
          draw
        end

      redriven = StuckDrawRedriver.redrive()

      for draw <- [recent, ahead | terminal] do
        refute draw.id in redriven
        assert jobs_for(ObservationDrawWorker, draw.id) == []
      end
    end

    test "the threshold is 15 minutes after pub(R), from the draw's rules" do
      inside = stuck_v6(-15 * 60 + 30)
      outside = stuck_v6(-15 * 60 - 30)
      redriven = StuckDrawRedriver.redrive()

      refute inside.id in redriven
      assert outside.id in redriven
    end

    test "pending_entropy draws are re-driven too" do
      draw = stuck_v6(-20 * 60)
      set_status!(draw, "pending_entropy")
      assert draw.id in StuckDrawRedriver.redrive()
    end

    test "idempotent: a second run inserts nothing" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      draw = stuck_v6(-20 * 60)
      id = draw.id

      assert id in StuckDrawRedriver.redrive()
      refute id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, id) == ["available"]
      assert_received {@event, ^ref, _, %{draw_id: ^id}}
      refute_received {@event, ^ref, _, %{draw_id: ^id}}
    end

    test "it changes nothing on the draw" do
      draw = stuck_v6(-20 * 60)
      before = Repo.query!("SELECT * FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)])
      assert draw.id in StuckDrawRedriver.redrive()

      assert Repo.query!("SELECT * FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)]) ==
               before
    end
  end

  describe "window jobs" do
    test "the re-driver never re-drives a window job" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      {_op, key} = create_v6_operator()

      open_round = round_at(60)

      open =
        put_v6_awaiting!(
          open_draw_with_entries(key),
          Schedule.weather_time_for_round(open_round),
          open_round
        )

      stuck = stuck_v6(-20 * 60)

      Repo.query!("DELETE FROM oban_jobs WHERE worker = $1", [inspect(FrequencyWindowWorker)])

      assert stuck.id in StuckDrawRedriver.redrive()
      StuckDrawRedriver.redrive()

      for t <- [open.freq_start, stuck.freq_start] do
        refute_enqueued(
          worker: FrequencyWindowWorker,
          args: %{freq_start: FrequencyWindowWorker.start_arg(t)}
        )
      end

      refute_enqueued(worker: FrequencyWindowWorker)
      refute_received {@event, ^ref, _, %{kind: :fetch, weather_time: nil}}
    end
  end

  describe "fetch jobs" do
    defp pending_next_hour do
      {_op, key} = create_v6_operator()
      now = DateTime.utc_now()

      wt =
        %{now | minute: 0, second: 0, microsecond: {0, 0}}
        |> DateTime.add(3600)

      draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(3 * 3600))

      Repo.query!("DELETE FROM oban_jobs WHERE args->>'weather_time' = $1", [
        WeatherObservationWorker.hour_arg(wt)
      ])

      {draw, wt}
    end

    test "an hour with pending draws before F gets its fetch job back, reported" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      {draw, wt} = pending_next_hour()

      refute draw.id in StuckDrawRedriver.redrive()

      assert_enqueued(
        worker: WeatherObservationWorker,
        args: %{weather_time: WeatherObservationWorker.hour_arg(wt)}
      )

      assert_received {@event, ^ref, %{count: 1},
                       %{kind: :fetch, protocol: :observation, weather_time: reported}}

      assert DateTime.compare(reported, wt) == :eq
    end

    test "a live fetch job is left alone, and a second run inserts nothing" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      {_draw, wt} = pending_next_hour()
      {:ok, _} = Oban.insert(WeatherObservationWorker.new_for_hour(wt))

      StuckDrawRedriver.redrive()
      StuckDrawRedriver.redrive()

      assert length(
               all_enqueued(
                 worker: WeatherObservationWorker,
                 args: %{weather_time: WeatherObservationWorker.hour_arg(wt)}
               )
             ) == 1

      refute_received {@event, ^ref, _, %{kind: :fetch, weather_time: ^wt}}
    end

    test "an hour already stored, or past F, gets no fetch job" do
      {_draw, wt} = pending_next_hour()
      put_observation!(Stations.primary().id, wt, "141;1025;85;2432")

      stale = stuck_v6(-20 * 60)
      stale_hour = WeatherObservationWorker.hour_arg(stale.weather_time)

      assert DateTime.compare(Schedule.fetch_deadline(stale.weather_time), DateTime.utc_now()) ==
               :lt

      StuckDrawRedriver.redrive()

      for hour <- [WeatherObservationWorker.hour_arg(wt), stale_hour] do
        refute_enqueued(worker: WeatherObservationWorker, args: %{weather_time: hour})
      end
    end

    test "a frequency draw in its window doesn't crash the re-drive and gets no fetch job" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      {_op, key} = create_freq_operator()
      t = aligned_freq_start(-(FreqSchedule.span_seconds() + 60))
      draw = put_freq_awaiting!(open_draw_with_entries(key), t, round_at(3600))

      assert is_list(StuckDrawRedriver.redrive())

      refute_enqueued(
        worker: FrequencyWindowWorker,
        args: %{freq_start: FrequencyWindowWorker.start_arg(t)}
      )

      refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
      refute_received {@event, ^ref, _, %{kind: :fetch, weather_time: nil}}
    end
  end

  describe "retired forecast draws" do
    test "a stranded draw with no lock schema is never read, re-driven or reported" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [@event, [:wallop_core, :v6, :overdue]])

      for status <- [:awaiting_entropy, :pending_entropy], job <- [nil, "cancelled"] do
        draw = stuck_forecast(status, -3 * 3600)
        if job, do: put_job!(@forecast_worker, draw.id, job)
        before = Repo.query!("SELECT * FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)])

        refute draw.id in StuckDrawRedriver.redrive()
        assert jobs_for(ObservationDrawWorker, draw.id) == []

        assert Repo.query!("SELECT * FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)]) ==
                 before

        id = draw.id
        refute_received {_, ^ref, _, %{draw_id: ^id}}
      end
    end
  end

  describe "the cron" do
    test "runs every ten minutes on wallop's own Oban" do
      {_, opts} =
        Application.fetch_env!(:wallop_core, Oban)[:plugins]
        |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

      assert {"*/10 * * * *", StuckDrawRedriver} in opts[:crontab]
    end

    test "the job runs a re-drive and succeeds" do
      draw = stuck_v6(-20 * 60)
      assert :ok = perform_job(StuckDrawRedriver, %{})
      assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
    end
  end

  describe "grid-frequency draws" do
    @freq_value "50012;50018;50012;49983;49980;49953;49912;49883"
    @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
    @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

    setup do
      ensure_infrastructure_key()

      Application.put_env(:wallop_core, DrandClient,
        req_options: [plug: {Req.Test, DrandClient}, retry: false]
      )

      Req.Test.stub(DrandClient, fn conn ->
        round = conn.path_info |> List.last() |> String.to_integer()

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature
        })
      end)

      on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
    end

    defp freq_draw(pub_offset, t \\ nil) do
      {_op, key} = create_freq_operator()
      round = round_at(pub_offset)

      draw =
        put_freq_awaiting!(
          open_draw_with_entries(key),
          t || FreqSchedule.freq_start_for_round(round),
          round
        )

      delete_jobs_for!(draw.id)
      draw
    end

    test "a frequency draw past pub(R) + 15 min with no live job gets its execution job back" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      draw = freq_draw(-20 * 60)
      id = draw.id

      assert id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, id) == ["available"]

      assert_received {@event, ^ref, %{count: 1},
                       %{kind: :execution, protocol: :frequency, draw_id: ^id}}

      refute id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, id) == ["available"]
    end

    test "not yet past pub(R) + 15 min: left alone" do
      draw = freq_draw(-10 * 60)
      refute draw.id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, draw.id) == []
    end

    test "a runnable job in any runnable state means the frequency draw is left alone" do
      for state <- @runnable_v6_states do
        draw = freq_draw(-20 * 60)
        put_job!(ObservationDrawWorker, draw.id, state)
        refute draw.id in StuckDrawRedriver.redrive(), state
      end
    end

    test "a cancelled ObservationDrawWorker job parks a frequency draw: a refusal stays put" do
      draw = freq_draw(-20 * 60)
      put_job!(ObservationDrawWorker, draw.id, "cancelled")

      refute draw.id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, draw.id) == ["cancelled"]
    end

    test "a lost window job is not re-inserted, even while T's window is open: the draw falls back by rule" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      t = aligned_freq_start(-(FreqSchedule.span_seconds() + 60))
      freq_draw(3600, t)

      StuckDrawRedriver.redrive()

      refute_enqueued(
        worker: FrequencyWindowWorker,
        args: %{freq_start: FrequencyWindowWorker.start_arg(t)}
      )

      refute_received {@event, ^ref, _, %{kind: :fetch, weather_time: nil}}
    end

    test "a re-driven frequency job re-reads the stored window: re-drive makes no choice" do
      draw = freq_draw(-20 * 60)
      put_frequency_window!(draw.freq_start, @freq_value)

      assert draw.id in StuckDrawRedriver.redrive()

      before =
        Repo.query!("SELECT status, freq_value, seed FROM draws WHERE id = $1", [
          Ecto.UUID.dump!(draw.id)
        ])

      assert before.rows == [["awaiting_entropy", nil, nil]]

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      done = Ash.get!(Draw, draw.id, authorize?: false)

      assert {done.status, done.freq_value, done.freq_fallback_reason} ==
               {:completed, @freq_value, nil}
    end
  end
end
