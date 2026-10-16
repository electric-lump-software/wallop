defmodule WallopCore.Entropy.StuckDrawRedriverTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  @moduletag :capture_log

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{EntropyWorker, ObservationDrawWorker, StuckDrawRedriver}
  alias WallopCore.Entropy.WeatherObservationWorker
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  @live_states ~w(available scheduled executing retryable suspended)
  @event [:wallop_core, :redrive, :reinserted]

  setup do
    original = Application.fetch_env!(:wallop_core, :redrive_forecast_draws)
    on_exit(fn -> Application.put_env(:wallop_core, :redrive_forecast_draws, original) end)
    :ok
  end

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  # The test DB is shared: only this test's own rows are touched.
  defp delete_jobs_for!(id),
    do: Repo.query!("DELETE FROM oban_jobs WHERE args->>'draw_id' = $1", [id])

  defp jobs_for(worker, id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT state FROM oban_jobs WHERE worker = $1 AND args->>'draw_id' = $2",
        [inspect(worker), id]
      )

    List.flatten(rows)
  end

  defp put_job!(worker, id, state) do
    {:ok, job} = Oban.insert(worker.new(%{draw_id: id}))
    Repo.query!("UPDATE oban_jobs SET state = $2 WHERE id = $1", [job.id, state])
    job
  end

  # A v6 draw whose round published `pub_offset` seconds from now, with its
  # stored hour well past F, and no job.
  defp stuck_v6(pub_offset) do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.truncate(:second)
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(pub_offset))
    delete_jobs_for!(draw.id)
    draw
  end

  # A forecast draw whose weather_time is `weather_offset` seconds from now,
  # with the lock's EntropyWorker job gone.
  defp stuck_forecast(weather_offset) do
    draw = create_draw(create_api_key())
    wt = DateTime.add(DateTime.utc_now(), weather_offset)

    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET weather_time = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        DateTime.to_naive(wt)
      ])
    end)

    delete_jobs_for!(draw.id)
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

  defp forecast_on, do: Application.put_env(:wallop_core, :redrive_forecast_draws, true)

  describe "observation-weather draws" do
    test "past pub(R) + 15m with no job: the execution job comes back, reported" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      draw = stuck_v6(-20 * 60)

      assert draw.id in StuckDrawRedriver.redrive()
      assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
      assert jobs_for(EntropyWorker, draw.id) == []

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

      # The Pruner removes the row: one more re-drive.
      Repo.query!("DELETE FROM oban_jobs WHERE id = $1", [cancelled.id])
      assert draw.id in StuckDrawRedriver.redrive()
      assert jobs_for(ObservationDrawWorker, draw.id) == ["available"]
    end

    test "a live job of either worker, in any live state, means the draw is left alone" do
      for worker <- [ObservationDrawWorker, EntropyWorker], state <- @live_states do
        draw = stuck_v6(-20 * 60)
        put_job!(worker, draw.id, state)

        refute draw.id in StuckDrawRedriver.redrive(), "#{inspect(worker)} #{state}"

        assert jobs_for(ObservationDrawWorker, draw.id) ==
                 if(worker == ObservationDrawWorker, do: [state], else: [])

        assert jobs_for(EntropyWorker, draw.id) ==
                 if(worker == EntropyWorker, do: [state], else: [])
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
      # Just inside and just outside, a few seconds either side.
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

  describe "fetch jobs" do
    # A v6 draw for the next whole hour (F still ahead), with its hour's
    # fetch job gone.
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
  end

  describe "forecast draws" do
    test "off by default: a stuck forecast draw is untouched and not even reported" do
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      refute StuckDrawRedriver.forecast_enabled?()
      draw = stuck_forecast(-20 * 60)
      before = Repo.query!("SELECT * FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)])

      refute draw.id in StuckDrawRedriver.redrive()

      assert jobs_for(EntropyWorker, draw.id) == []
      assert jobs_for(ObservationDrawWorker, draw.id) == []

      assert Repo.query!("SELECT * FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)]) ==
               before

      id = draw.id
      refute_received {@event, ^ref, _, %{draw_id: ^id}}
    end

    test "on: past weather_time + 15m with no job, EntropyWorker comes back" do
      forecast_on()
      ref = :telemetry_test.attach_event_handlers(self(), [@event])
      draw = stuck_forecast(-20 * 60)
      id = draw.id

      assert id in StuckDrawRedriver.redrive()
      assert_enqueued(worker: EntropyWorker, args: %{draw_id: id})
      assert jobs_for(ObservationDrawWorker, id) == []

      assert_received {@event, ^ref, %{count: 1},
                       %{kind: :execution, protocol: :forecast, draw_id: ^id}}

      # Idempotent.
      refute id in StuckDrawRedriver.redrive()
      assert jobs_for(EntropyWorker, id) == ["available"]
    end

    test "on: a live job blocks it, a finished one doesn't, and a cancelled v6 worker job is no marker" do
      forecast_on()

      for state <- @live_states do
        draw = stuck_forecast(-20 * 60)
        put_job!(EntropyWorker, draw.id, state)
        refute draw.id in StuckDrawRedriver.redrive(), state
        assert jobs_for(EntropyWorker, draw.id) == [state]
      end

      # EntropyWorker's own uniqueness counts a completed job; the re-drive
      # counts only live ones.
      for state <- ~w(completed discarded) do
        draw = stuck_forecast(-20 * 60)
        put_job!(EntropyWorker, draw.id, state)
        assert draw.id in StuckDrawRedriver.redrive(), state
      end

      draw = stuck_forecast(-20 * 60)
      put_job!(ObservationDrawWorker, draw.id, "cancelled")
      assert draw.id in StuckDrawRedriver.redrive()
    end

    test "on: not yet past the threshold is left alone" do
      forecast_on()
      draw = stuck_forecast(-5 * 60)
      refute draw.id in StuckDrawRedriver.redrive()
      assert jobs_for(EntropyWorker, draw.id) == []
    end
  end

  describe "the cron" do
    test "runs every ten minutes on wallop's own Oban" do
      {_, opts} =
        Application.fetch_env!(:wallop_core, Oban)[:plugins]
        |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

      assert {"*/10 * * * *", StuckDrawRedriver} in opts[:crontab]
    end

    test "the forecast flag is off in config" do
      assert Application.fetch_env!(:wallop_core, :redrive_forecast_draws) == false
    end

    test "the job runs a re-drive and succeeds" do
      draw = stuck_v6(-20 * 60)
      assert :ok = perform_job(StuckDrawRedriver, %{})
      assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
    end
  end
end
