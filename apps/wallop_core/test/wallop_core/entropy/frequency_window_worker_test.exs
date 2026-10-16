defmodule WallopCore.Entropy.FrequencyWindowWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{ElexonFreqClient, FrequencyWindowWorker}
  alias WallopCore.Frequency.{Schedule, Windows}
  alias WallopCore.Repo
  alias WallopCore.Resources.Draw

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
  @poll [:wallop_core, :frequency, :poll]
  @stored [:wallop_core, :frequency, :stored]
  @store_refused [:wallop_core, :frequency, :store_refused]
  @poll_error [:wallop_core, :frequency, :poll_error]

  setup do
    Application.put_env(:wallop_core, ElexonFreqClient, plug: {Req.Test, ElexonFreqClient})
    on_exit(fn -> Application.delete_env(:wallop_core, ElexonFreqClient) end)
  end

  defp freq_draws(t, n) do
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))
    {_op, key} = create_freq_operator()
    for _ <- 1..n, do: put_freq_awaiting!(open_draw_with_entries(key), t, round)
  end

  defp elexon(t, value) do
    test_pid = self()

    Req.Test.stub(ElexonFreqClient, fn conn ->
      send(test_pid, :fetched)
      Plug.Conn.send_resp(conn, 200, elexon_body(t, value))
    end)
  end

  defp run(t),
    do: perform_job(FrequencyWindowWorker, %{freq_start: FrequencyWindowWorker.start_arg(t)})

  defp attach(events), do: :telemetry_test.attach_event_handlers(self(), events)

  defp status(draw), do: Ash.get!(Draw, draw.id, authorize?: false).status

  # now - T is in [165, 180): the window is open and the first poll is due.
  defp inside, do: aligned_freq_start(-(Schedule.span_seconds() + 60))

  describe "new_for_start/1" do
    test "canonical args, first poll at T + 135 s" do
      t = ~U[2026-10-14 19:54:15.000000Z]
      job = FrequencyWindowWorker.new_for_start(t)
      assert job.changes.args == %{freq_start: "2026-10-14T19:54:15Z"}
      assert job.changes.scheduled_at == ~U[2026-10-14 19:56:30.000000Z]
      assert job.changes.queue == "weather"
      assert FrequencyWindowWorker.start_arg(~U[2026-10-14 19:54:15Z]) == "2026-10-14T19:54:15Z"
    end

    test "refuses anything but a UTC window start" do
      for bad <- [
            ~U[2026-10-14 19:54:16.000000Z],
            ~U[2026-10-14 19:54:15.000001Z],
            %{~U[2026-10-14 19:54:15.000000Z] | time_zone: "Europe/London", zone_abbr: "BST"}
          ] do
        assert_raise ArgumentError, fn -> FrequencyWindowWorker.new_for_start(bad) end
      end
    end

    test "one live job per T; a finished one never blocks a new one" do
      t = ~U[2030-01-01 00:00:15.000000Z]
      {:ok, a} = Oban.insert(FrequencyWindowWorker.new_for_start(t))
      {:ok, b} = Oban.insert(FrequencyWindowWorker.new_for_start(t))
      assert b.conflict? and a.id == b.id

      Repo.query!("UPDATE oban_jobs SET state = 'completed' WHERE id = $1", [a.id])
      {:ok, c} = Oban.insert(FrequencyWindowWorker.new_for_start(t))
      refute c.conflict?
      assert c.state in ["scheduled", "available"]
      Repo.query!("DELETE FROM oban_jobs WHERE id = ANY($1)", [[a.id, c.id]])
    end
  end

  describe "storing" do
    test "stores the window once for every waiting draw of T, and leaves their status alone" do
      t = inside()
      [a, b] = freq_draws(t, 2)
      elexon(t, @value)
      ref = attach([@poll, @stored, @store_refused])

      assert :ok = run(t)
      assert Windows.for_draw(a).value == @value
      assert Windows.for_draw(b).value == @value
      assert Windows.for_start(t).raw == elexon_body(t, @value)
      assert {status(a), status(b)} == {:awaiting_entropy, :awaiting_entropy}

      poll = %{freq_start: t, ok?: true, error: nil}
      assert_received {@poll, ^ref, %{count: 1}, ^poll}
      stored = %{freq_start: t}
      assert_received {@stored, ^ref, %{count: 1}, ^stored}
      refute_received {@store_refused, ^ref, _, _}
    end

    test "an invalid window stores nothing, keeps polling and says why" do
      t = inside()
      [d] = freq_draws(t, 1)
      ref = attach([@poll])
      elexon(t, "50012;50018;00000;49983;49980;49953;49912;49883")

      assert {:snooze, secs} = run(t)
      # F is minutes away, so the next poll is a full interval on.
      assert secs == Schedule.poll_interval_seconds()
      assert Windows.for_start(t) == nil
      assert status(d) == :awaiting_entropy
      stamp = Calendar.strftime(DateTime.add(t, 30), "%Y-%m-%dT%H:%M:%SZ")

      meta = %{freq_start: t, ok?: false, error: {:zero, stamp}}
      assert_received {@poll, ^ref, %{count: 1}, ^meta}
    end

    test "a stuck feed is an invalid window too" do
      t = inside()
      freq_draws(t, 1)
      ref = attach([@poll])
      elexon(t, "50000;50000;50000;50000;50000;50000;49912;49883")

      assert {:snooze, _} = run(t)
      assert Windows.for_start(t) == nil
      meta = %{freq_start: t, ok?: false, error: :stuck}
      assert_received {@poll, ^ref, %{count: 1}, ^meta}
    end

    test "the last poll is made at least 2 s before F" do
      # now - T is in [325, 340): F (T + 345 s) is 5 to 20 s away, so the
      # deadline, not the poll interval, sets the snooze.
      t = aligned_freq_start(-(Schedule.span_seconds() + Schedule.fetch_window_seconds() - 20))
      f = Schedule.fetch_deadline(t)
      freq_draws(t, 1)
      elexon(t, "50012;50018;00000;49983;49980;49953;49912;49883")

      before = WallopCore.DbClock.now()
      assert {:snooze, secs} = run(t)
      assert secs >= 1 and secs < Schedule.poll_interval_seconds()
      assert secs <= DateTime.diff(f, before) - 2
    end

    test "after F it stops without fetching or storing" do
      t = aligned_freq_start(-(Schedule.span_seconds() + Schedule.fetch_window_seconds() + 60))
      freq_draws(t, 1)
      elexon(t, @value)
      assert :ok = run(t)
      refute_received :fetched
      assert Windows.for_start(t) == nil
    end

    test "no waiting draw, or T already stored: done without fetching" do
      t = inside()
      elexon(t, @value)
      assert :ok = run(t)

      freq_draws(t, 1)
      {:ok, _} = Windows.store(t, @value, elexon_body(t, @value))
      assert :ok = run(t)
      refute_received :fetched
    end

    test "a store refused because another run stored T first counts as done" do
      t = inside()
      [d] = freq_draws(t, 1)
      other = "50000;50001;50000;50001;50000;50001;50000;50001"
      ref = attach([@stored, @store_refused])

      # The other run stores while this one is fetching.
      Req.Test.stub(ElexonFreqClient, fn conn ->
        {:ok, _} = Windows.store(t, other, elexon_body(t, other))
        Plug.Conn.send_resp(conn, 200, elexon_body(t, @value))
      end)

      log = capture_log(fn -> assert :ok = run(t) end)

      assert Windows.for_draw(d).value == other
      refute_received {@stored, ^ref, _, _}
      refute_received {@store_refused, ^ref, _, _}
      refute log =~ "refused"
    end

    test "a store refused inside a caller's transaction is reported, not retried silently" do
      t = inside()
      freq_draws(t, 1)
      elexon(t, @value)
      ref = attach([@store_refused])

      capture_log(fn ->
        assert {:ok, {:snooze, _}} = Repo.transaction(fn -> run(t) end)
      end)

      meta = %{freq_start: t, reason: :nested_transaction}
      assert_received {@store_refused, ^ref, %{count: 1}, ^meta}
      assert Windows.for_start(t) == nil
    end

    test "a store the database refuses is reported as :refused" do
      t = inside()
      [d] = freq_draws(t, 1)
      ref = attach([@store_refused])

      # While the fetch runs, the draw stops waiting, so the store trigger
      # refuses the insert (no waiting draw of T).
      Req.Test.stub(ElexonFreqClient, fn conn ->
        with_triggers_off(fn ->
          Repo.query!("UPDATE draws SET status = 'completed' WHERE id = $1", [
            Ecto.UUID.dump!(d.id)
          ])
        end)

        Plug.Conn.send_resp(conn, 200, elexon_body(t, @value))
      end)

      log = capture_log(fn -> assert :ok = run(t) end)

      meta = %{freq_start: t, reason: :refused}
      assert_received {@store_refused, ^ref, %{count: 1}, ^meta}
      assert log =~ "refused (refused)"
      assert Windows.for_start(t) == nil
    end
  end

  test "before the first poll it waits without fetching" do
    t = aligned_freq_start(-60)
    freq_draws(t, 1)
    elexon(t, @value)
    assert {:snooze, secs} = run(t)
    assert secs >= 1
    refute_received :fetched
  end

  describe "errors" do
    test "a fetch that raises snoozes until F instead of failing the job" do
      t = inside()
      [d] = freq_draws(t, 1)
      ref = attach([@poll, @poll_error])
      Req.Test.stub(ElexonFreqClient, fn _conn -> raise "boom" end)

      log = capture_log(fn -> assert {:snooze, _} = run(t) end)
      assert log =~ "RuntimeError"
      refute log =~ "boom"
      assert status(d) == :awaiting_entropy

      poll = %{freq_start: t, ok?: false, error: {:raised, :error}}
      assert_received {@poll, ^ref, %{count: 1}, ^poll}
      poll_error = %{freq_start: t, kind: :error}
      assert_received {@poll_error, ^ref, %{count: 1}, ^poll_error}
    end

    @tag :slow
    test "a fetch that hangs is cut off at 8 s, killed, and the job snoozes" do
      t = inside()
      freq_draws(t, 1)
      ref = attach([@poll])
      test_pid = self()

      Req.Test.stub(ElexonFreqClient, fn conn ->
        Process.sleep(12_000)
        send(test_pid, :fetch_finished)
        Plug.Conn.send_resp(conn, 200, elexon_body(t, @value))
      end)

      {us, result} = :timer.tc(fn -> run(t) end)
      assert {:snooze, _} = result
      assert us < FrequencyWindowWorker.timeout(%Oban.Job{}) * 1_000

      meta = %{freq_start: t, ok?: false, error: :poll_timeout}
      assert_received {@poll, ^ref, %{count: 1}, ^meta}
      # The fetch was killed, not left running.
      refute_receive :fetch_finished, 5_000
    end

    test "when the database clock can't be read it snoozes, even well past F on the BEAM clock" do
      t = aligned_freq_start(-3600)
      ref = attach([@poll_error])

      # Every query in an aborted transaction fails, so the first clock read
      # raises and so does the read after the failure.
      log =
        capture_log(fn ->
          result =
            Repo.transaction(fn ->
              {:error, _} = Repo.query("SELECT 1/0")
              Repo.rollback(run(t))
            end)

          send(self(), {:result, result})
        end)

      assert_received {:result, {:error, {:snooze, s}}}
      assert s == Schedule.poll_interval_seconds()
      assert log =~ "Postgrex.Error"
      meta = %{freq_start: t, kind: :error}
      assert_received {@poll_error, ^ref, %{count: 1}, ^meta}
    end

    test "logs and telemetry carry no body" do
      t = inside()
      freq_draws(t, 1)
      ref = attach([@poll, @poll_error, @store_refused])
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          for {status, body} <- [
                {503, ~s({"detail": "BODY-SHOULD-NOT-APPEAR"})},
                {200, ~s({"data": "BODY-SHOULD-NOT-APPEAR"})},
                {200, "BODY-SHOULD-NOT-APPEAR"}
              ] do
            Req.Test.stub(ElexonFreqClient, &Plug.Conn.send_resp(&1, status, body))
            assert {:snooze, _} = run(t)
          end
        end)

      refute log =~ "BODY-SHOULD-NOT-APPEAR"

      errors =
        for _ <- 1..3 do
          assert_received {@poll, ^ref, %{count: 1}, %{error: error} = meta}
          refute inspect(meta) =~ "BODY-SHOULD-NOT-APPEAR"
          error
        end

      assert errors == [{:unexpected_status, 503}, :invalid_response, :invalid_json]
    end

    test "a malformed or non-canonical argument is cancelled" do
      for arg <- [
            "nope",
            "2026-10-14T19:54:16Z",
            "2026-10-14T19:54:15.000Z",
            "2026-10-14T19:54:15.5Z",
            "2026-10-14T19:54:15+00:00",
            "2026-10-14T20:54:15+01:00"
          ] do
        assert {:cancel, :invalid_freq_start} =
                 perform_job(FrequencyWindowWorker, %{freq_start: arg}),
               arg
      end

      assert {:cancel, :invalid_freq_start} = perform_job(FrequencyWindowWorker, %{other: 1})
    end
  end

  describe "the job" do
    test "the job timeout is at most 30 s and fits inside the poll interval" do
      timeout = FrequencyWindowWorker.timeout(%Oban.Job{})
      assert timeout <= 30_000
      assert timeout < Schedule.poll_interval_seconds() * 1_000
    end

    test "the weather queue runs on the wallop service" do
      queues = Application.fetch_env!(:wallop_core, Oban) |> Keyword.fetch!(:queues)
      assert queues[:weather] >= 2
    end

    test "the next poll is at least 2 s before F, and polling stops when it can't be" do
      t = ~U[2026-10-14 19:54:00.000000Z]
      f = Schedule.fetch_deadline(t)
      at = fn ms -> DateTime.add(f, -ms, :millisecond) end

      assert FrequencyWindowWorker.next_poll(at.(60_000), t) ==
               {:snooze, Schedule.poll_interval_seconds()}

      assert FrequencyWindowWorker.next_poll(at.(10_000), t) == {:snooze, 8}
      assert FrequencyWindowWorker.next_poll(at.(3_000), t) == {:snooze, 1}
      assert FrequencyWindowWorker.next_poll(at.(2_999), t) == :ok
      assert FrequencyWindowWorker.next_poll(at.(500), t) == :ok
      assert FrequencyWindowWorker.next_poll(at.(-1_000), t) == :ok
    end

    test "window_state/2 mirrors wallop_freq_store_allowed exactly" do
      t = ~U[2026-10-14 19:54:00.000000Z]
      from = Schedule.store_from(t)
      f = Schedule.fetch_deadline(t)

      for {now, state} <- [
            {DateTime.add(from, -1, :microsecond), :not_yet},
            {from, :open},
            {f, :open},
            {DateTime.add(f, 1, :microsecond), :closed}
          ] do
        assert FrequencyWindowWorker.window_state(now, t) == state

        %{rows: [[sql]]} =
          Repo.query!("SELECT wallop_freq_store_allowed($1, $2)", [
            DateTime.to_naive(t),
            DateTime.to_naive(now)
          ])

        assert sql == (state == :open)
      end
    end
  end

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end
end
