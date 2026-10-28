defmodule WallopCore.ObanShutdownDrainTest do
  @moduledoc """
  Stops a private Oban instance while a job is running and checks what the
  shutdown grace period does with it. A job that finishes inside the grace
  period completes and nothing is orphaned; a job that outlives it is
  reported as orphaned and left `executing`, and the app's shutdown handler
  logs it. This uses a test-only sleeping worker, so it proves Oban's
  drain behaviour under our settings, not the real workers' runtimes;
  `WallopCore.DeployDrainConfigTest` ties the grace period to those.
  """
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureLog

  defmodule SleepyWorker do
    @moduledoc false
    use Oban.Worker, queue: :drain_test, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"ms" => ms}}) do
      Process.sleep(ms)
      :ok
    end
  end

  @name __MODULE__.Oban

  setup do
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler,
      [[:oban, :job, :start], [:oban, :queue, :shutdown]],
      fn event, _measurements, meta, _ ->
        if meta.conf.name == @name, do: send(test_pid, {event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp start_oban(grace_ms) do
    start_supervised!(
      {Oban,
       name: @name,
       repo: WallopCore.Repo,
       testing: :disabled,
       queues: [drain_test: 1],
       plugins: false,
       peer: {Oban.Peers.Isolated, []},
       notifier: Oban.Notifiers.Isolated,
       shutdown_grace_period: grace_ms}
    )
  end

  defp run_until_started(sleep_ms) do
    {:ok, job} = Oban.insert(@name, SleepyWorker.new(%{"ms" => sleep_ms}))
    assert_receive {[:oban, :job, :start], %{job: %{id: id}}}, 5_000
    assert id == job.id
    job
  end

  defp stop_and_collect_shutdown do
    stop_supervised!(@name)
    assert_receive {[:oban, :queue, :shutdown], %{queue: "drain_test", orphaned: orphaned}}, 1_000
    orphaned
  end

  defp state_of(job), do: Repo.reload!(job).state

  test "a job that finishes inside the grace period completes and nothing is orphaned" do
    start_oban(3_000)
    job = run_until_started(1_000)

    log = capture_log([level: :error], fn -> assert stop_and_collect_shutdown() == [] end)

    assert state_of(job) == "completed"
    refute log =~ "orphaned jobs"
  end

  test "a job that outlives the grace period is orphaned, left executing and logged" do
    start_oban(500)
    job = run_until_started(10_000)

    log = capture_log([level: :error], fn -> assert stop_and_collect_shutdown() == [job.id] end)

    assert state_of(job) == "executing"
    assert log =~ "Oban queue drain_test shut down with orphaned jobs: [#{job.id}]"
  end
end
