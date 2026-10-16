defmodule WallopCore.Invariants.ObservationAndExecutionTest do
  @moduledoc """
  Group B: invariants delivered by later tasks (INV-7 to INV-11, and INV-8b).

  Most are written now against the planned interfaces and tagged
  `:pending_task_N`; each task removes its tag when it lands. The cases
  that already hold through the database guard are live now and say so.
  See `WallopCore.Invariants.SuiteTest` for the suite's rules.
  """
  use WallopCore.InvariantCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  @moduletag :invariant

  # Planned modules, not yet in lib. Remove each from this list once it exists.
  @compile {:no_warn_undefined,
            [
              WallopCore.Entropy.ObservationDrawWorker,
              WallopCore.Entropy.StuckDrawRedriver
            ]}

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, EntropyWorker, ObservationDrawWorker, StuckDrawRedriver}
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @value "141;1025;85;2432"
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @drand_args %{
    drand_randomness: String.duplicate("a", 64),
    drand_signature: "sig",
    drand_response: "{}"
  }

  defp reload(draw), do: Ash.get!(Draw, draw.id, authorize?: false, load: [:expected_result_at])

  # The drand round published `offset` seconds from now (negative: ago).
  defp round_at(offset),
    do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  # A v6 draw in awaiting_entropy whose stored weather_time is `wt_offset`
  # seconds from now and whose drand round publishes `pub_offset` seconds
  # from now. put_v6_awaiting!/4 signs the round's own hour; the stored
  # weather_time is placed for the window under test.
  defp v6_draw(wt_offset, pub_offset, key \\ nil) do
    key = key || elem(create_v6_operator(), 1)
    wt = DateTime.utc_now() |> DateTime.add(wt_offset) |> DateTime.truncate(:second)
    put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(pub_offset))
  end

  defp to_pending!(draw) do
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    reload(draw)
  end

  defp reading(draw, value),
    do: %{value: value, raw: "[]", observation_time: draw.weather_time}

  defp complete(draw, set_sql, params \\ []) do
    try_sql(
      "UPDATE draws SET status = 'completed', executed_at = $2, #{set_sql} WHERE id = $1",
      [dump(draw.id), NaiveDateTime.utc_now() | params]
    )
  end

  # Moves a draw's hour, its observation and every draw of that hour an hour
  # into the past with every trigger off, so "after F" holds while the
  # stored row stays.
  defp shift_window_back!(draw) do
    wt = DateTime.to_naive(draw.weather_time)

    with_triggers_off(fn ->
      Repo.query!(
        "UPDATE draws SET weather_time = weather_time - interval '1 hour' WHERE weather_time = $1",
        [wt]
      )

      Repo.query!(
        "UPDATE weather_observations SET observation_time = observation_time - interval '1 hour' WHERE observation_time = $1",
        [wt]
      )
    end)
  end

  defp store(station, draw, value \\ @value),
    do: Observations.store(station, reading(draw, value))

  # Three v6 draws of one operator sharing one stored weather_time,
  # `wt_offset` seconds from now, as v6_draw/3 places it: one observation
  # hour, so one reading for all three.
  defp three_draws_sharing_wt(wt_offset, pub_offset \\ 3600) do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(wt_offset) |> DateTime.truncate(:second)
    for _ <- 1..3, do: put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(pub_offset))
  end

  # The first store for the hour wins; any second one, a different value or
  # the same, is refused; every draw of the hour reads the one row.
  defp assert_one_reading_per_hour([a, b, c] = draws, station) do
    assert {:ok, obs} = store(station, a)

    for {draw, value} <- [{b, "142;1025;85;2432"}, {c, @value}] do
      assert {:error, error} = store(station, draw, value)
      assert error_text(error) =~ "an observation is already stored for this hour"
    end

    for draw <- draws do
      assert %{id: id, station: ^station, value: @value} = Observations.for_draw(draw)
      assert id == obs.id
    end
  end

  # ── INV-7 ─────────────────────────────────────────────────────────

  describe "INV-7 one (station, value) per hour; every draw of the hour completes with it or the fallback" do
    test "INV-7 one reading per hour, shared by every draw of the hour (primary)" do
      # Five minutes after weather_time: always in the primary window.
      assert_one_reading_per_hour(three_draws_sharing_wt(-5 * 60), Stations.primary().id)
    end

    test "INV-7 one reading per hour, shared by every draw of the hour (backup)" do
      # Five minutes before F: always in the backup window.
      assert_one_reading_per_hour(three_draws_sharing_wt(-(@w - 5 * 60)), Stations.backup().id)
    end

    test "INV-7 the hour stores one observation, from one station" do
      draw = v6_draw(-5 * 60, 3600)

      assert {:ok, _} = store(Stations.primary().id, draw)

      assert error_text(elem(store(Stations.primary().id, draw), 1)) =~
               "an observation is already stored for this hour"

      # The backup is refused too (its window is closed now, and the hour
      # has its row).
      assert {:error, _} = store(Stations.backup().id, draw)
      assert Observations.for_draw(draw).station == Stations.primary().id
    end

    test "INV-7 every draw of the hour completes with the hour's reading, never another or the fallback" do
      draws = three_draws_sharing_wt(-(@w - 5 * 60), -10)
      {:ok, obs} = store(Stations.backup().id, hd(draws))
      shift_window_back!(hd(draws))
      message = "v6 draw must complete with its stored observation"

      for draw <- draws do
        draw = to_pending!(draw)

        assert complete(draw, "weather_fallback_reason = $3", [LandObs.fallback_reason()]) ==
                 message

        assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
                 "1;1000;1;1"
               ]) == message

        assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
                 obs.value
               ]) == nil
      end
    end

    test "INV-7 a stored observation can't be updated, deleted or truncated" do
      draw = v6_draw(-5 * 60, 3600)
      {:ok, _} = store(Stations.primary().id, draw)
      wt = DateTime.to_naive(draw.weather_time)

      for sql <- [
            "UPDATE weather_observations SET value = '1;1000;1;1' WHERE observation_time = $1",
            "DELETE FROM weather_observations WHERE observation_time = $1"
          ] do
        assert try_sql(sql, [wt]) == "weather observations are write-once", sql
      end

      # The sandbox never commits, so the row's deferred commit-time check is
      # still queued, and PostgreSQL refuses TRUNCATE for that before any
      # trigger runs. Run the queued check now (it passes: before F) so the
      # TRUNCATE meets the write-once trigger, as it would after a commit.
      Repo.query!("SET CONSTRAINTS weather_observations_commit_deadline IMMEDIATE")
      assert try_sql("TRUNCATE weather_observations", []) == "weather observations are write-once"
    end

    # Outside the sandbox: a committed row, then UPDATE, DELETE and TRUNCATE
    # in real transactions, with no queued trigger events.
    test "INV-7 a committed observation can't be updated, deleted or truncated" do
      draw = unboxed_v6_draw(-5 * 60)
      assert {:ok, _} = unboxed(fn -> store(Stations.primary().id, draw) end)
      wt = DateTime.to_naive(draw.weather_time)

      for {sql, params} <- [
            {"UPDATE weather_observations SET value = '1;1000;1;1' WHERE observation_time = $1",
             [wt]},
            {"DELETE FROM weather_observations WHERE observation_time = $1", [wt]},
            {"TRUNCATE weather_observations", []}
          ] do
        assert unboxed(fn -> try_sql(sql, params) end) == "weather observations are write-once",
               sql
      end

      assert stored_rows(draw) == 1
    end
  end

  # ── INV-8 ─────────────────────────────────────────────────────────

  describe "INV-8 completion matches the stored observation or the fallback rule, at or after pub(R)" do
    # Live now: the draws guard checks pub(R) before it reads the store.
    test "INV-8 a v6 draw can't complete before its drand round publishes" do
      draw = v6_draw(-(@w + 60), 600) |> to_pending!()

      for executed_at <- [nil, NaiveDateTime.utc_now()] do
        assert try_sql(
                 "UPDATE draws SET status = 'completed', executed_at = $2, weather_fallback_reason = $3 WHERE id = $1",
                 [dump(draw.id), executed_at, LandObs.fallback_reason()]
               ) == "v6 draw cannot complete before its drand round publishes"
      end
    end

    test "INV-8 with an observation stored, only that observation completes the draw" do
      draw = v6_draw(-(@w - 5 * 60), -10)
      {:ok, obs} = store(Stations.backup().id, draw)
      shift_window_back!(draw)
      draw = to_pending!(draw)
      message = "v6 draw must complete with its stored observation"

      assert complete(
               draw,
               "weather_value = '1;1000;1;1', weather_observation_time = weather_time"
             ) ==
               message

      assert complete(draw, "weather_fallback_reason = $3", [LandObs.fallback_reason()]) ==
               message

      assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
               obs.value
             ]) == nil
    end

    test "INV-8 with nothing stored, only the rule's fallback completes, and only after F" do
      message = "v6 draw may fall back only after the fetch deadline with nothing stored"
      fallback = "weather_fallback_reason = $3"

      before_f = v6_draw(-5 * 60, -10) |> to_pending!()
      assert complete(before_f, fallback, [LandObs.fallback_reason()]) == message

      after_f = v6_draw(-(@w + 60), -10) |> to_pending!()
      assert complete(after_f, fallback, ["unreachable"]) == message

      assert complete(after_f, "weather_value = $3, weather_observation_time = weather_time", [
               @value
             ]) == message

      assert complete(after_f, fallback, [LandObs.fallback_reason()]) == nil
    end

    @tag :pending_task_10
    test "INV-8 execute_v6 records the stored observation, at or after pub(R)" do
      ensure_infrastructure_key()
      draw = v6_draw(-(@w - 5 * 60), -10)
      {:ok, obs} = store(Stations.backup().id, draw)
      shift_window_back!(draw)

      done = execute_v6!(draw)
      assert done.status == :completed
      assert {done.weather_value, done.weather_fallback_reason} == {obs.value, nil}
      assert DateTime.compare(done.executed_at, Quicknet.pub_time(done.drand_round)) != :lt
    end

    @tag :pending_task_10
    test "INV-8 execute_v6 falls back by rule when nothing is stored by F, at or after pub(R)" do
      ensure_infrastructure_key()
      done = execute_v6!(v6_draw(-(@w + 60), -10))

      assert done.status == :completed
      assert {done.weather_value, done.weather_observation_time} == {nil, nil}
      assert done.weather_fallback_reason == LandObs.fallback_reason()
      assert DateTime.compare(done.executed_at, Quicknet.pub_time(done.drand_round)) != :lt
    end

    @tag :pending_task_10
    test "INV-8 execute_v6 refuses before pub(R), even after F" do
      draw = v6_draw(-(@w + 60), 600)
      pending = draw |> to_pending!()

      assert {:error, _} =
               pending
               |> Ash.Changeset.for_update(:execute_v6, @drand_args)
               |> Ash.update(authorize?: false)

      assert reload(draw).status == :pending_entropy
    end
  end

  defp execute_v6!(draw) do
    draw
    |> to_pending!()
    |> Ash.Changeset.for_update(:execute_v6, @drand_args)
    |> Ash.update!(authorize?: false)
  end

  # ── INV-8b ────────────────────────────────────────────────────────

  # The commit-time check's refusal: the store's deferred constraint
  # trigger raises exactly this.
  @commit_late "an observation must commit by its fetch deadline"

  describe "INV-8b a stored observation's commit time is at or before F" do
    # The sandbox wraps each test in one transaction, so a commit can't
    # happen in it. These tests run their fixtures and the store transaction
    # outside it (Sandbox.unboxed_run/2, as V6LockReceiptRaceTest does), on
    # real connections that really commit, and delete what they created.
    # Every time comparison uses the database clock.
    @tag :slow
    test "INV-8b an insert made before F but committed after F is refused at commit" do
      # F is a few seconds ahead: the store's statement runs inside the
      # backup window, before F; the commit waits until F has passed.
      draw = unboxed_v6_draw(-(@w - 4))
      f = Schedule.fetch_deadline(draw.weather_time)

      outcome =
        store_and_commit(draw, Stations.backup().id, fn ->
          assert DateTime.compare(db_now(), f) == :lt
          wait_until_db_clock_after(f)
        end)

      assert outcome == {:refused, @commit_late}
      assert stored_rows(draw) == 0
    end

    @tag :slow
    test "INV-8b an insert committed before F is stored, once" do
      # Positive control: same path, F 35 minutes ahead, commit at once.
      draw = unboxed_v6_draw(-5 * 60)
      f = Schedule.fetch_deadline(draw.weather_time)

      outcome =
        store_and_commit(draw, Stations.primary().id, fn ->
          assert DateTime.compare(db_now(), f) == :lt
        end)

      assert outcome == :committed
      assert stored_rows(draw) == 1
    end
  end

  # A v6 draw committed outside the sandbox, for its own fresh operator,
  # deleted at the end of the test.
  defp unboxed_v6_draw(wt_offset) do
    {operator, draw} =
      unboxed(fn ->
        {operator, key} = create_v6_operator()
        {operator, v6_draw(wt_offset, 3600, key)}
      end)

    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    draw
  end

  # Inserts the hour's reading in a real transaction, runs `before_commit`
  # inside it, then commits. :committed, or {:refused, message}. A raw INSERT:
  # Observations.store/2 refuses to run inside a caller's transaction, so the
  # only way to hold a store open is to bypass it, which is what the
  # database's commit-time check is for.
  defp store_and_commit(draw, station, before_commit) do
    unboxed(fn ->
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '10s'")

          Repo.query!(
            """
            INSERT INTO weather_observations (id, station, observation_time, value, raw)
            VALUES (gen_random_uuid(), $1, $2, $3, '[]')
            """,
            [station, DateTime.to_naive(draw.weather_time), @value]
          )

          before_commit.()
        end)
    end)

    :committed
  rescue
    e in Postgrex.Error -> {:refused, e.postgres.message}
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")
    DateTime.from_naive!(now, "Etc/UTC")
  end

  defp wait_until_db_clock_after(t) do
    if DateTime.compare(db_now(), t) == :gt do
      :ok
    else
      Process.sleep(200)
      wait_until_db_clock_after(t)
    end
  end

  defp stored_rows(draw) do
    unboxed(fn ->
      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM weather_observations WHERE observation_time = $1", [
          DateTime.to_naive(draw.weather_time)
        ])

      n
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp delete_operator!(operator_id) do
    id = dump(operator_id)
    draws = "SELECT id FROM draws WHERE operator_id = $1"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      # The observation store's table may not exist yet.
      %{rows: [[store]]} = Repo.query!("SELECT to_regclass('weather_observations')::text")

      if store,
        do:
          Repo.query!(
            "DELETE FROM weather_observations WHERE observation_time IN (SELECT weather_time FROM draws WHERE operator_id = $1)",
            [id]
          )

      for sql <- [
            "DELETE FROM operator_receipts WHERE operator_id = $1",
            "DELETE FROM add_entries_idempotency WHERE draw_id IN (#{draws})",
            "DELETE FROM entries WHERE draw_id IN (#{draws})",
            "DELETE FROM draws WHERE operator_id = $1",
            "DELETE FROM api_keys WHERE operator_id = $1",
            "DELETE FROM operator_signing_keys WHERE operator_id = $1",
            "DELETE FROM operators_versions WHERE version_source_id = $1",
            "DELETE FROM operators WHERE id = $1"
          ] do
        Repo.query!(sql, [id])
      end
    end)
  end

  # ── INV-9 ─────────────────────────────────────────────────────────

  # The draws guard's backstop refusal: the guard raises exactly this.
  @no_fail_after_drand "a v6 draw can't fail once its drand randomness is stored"

  describe "INV-9 after drand is fetched, a v6 draw is never marked failed" do
    setup do
      ensure_infrastructure_key()
      test_pid = self()

      Application.put_env(:wallop_core, DrandClient,
        req_options: [plug: {Req.Test, DrandClient}, retry: false]
      )

      # Echoes the requested round, so the client's round check passes and
      # the fetch succeeds. Reports each fetch to the test.
      Req.Test.stub(DrandClient, fn conn ->
        round = conn.path_info |> List.last() |> String.to_integer()
        send(test_pid, {:drand_fetched, round})

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => String.duplicate("ab", 48)
        })
      end)

      on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
    end

    # The failure under test must come after a successful fetch of the
    # draw's own round.
    defp assert_fetched(draw) do
      round = draw.drand_round
      assert_received {:drand_fetched, ^round}
    end

    # Makes execute_v6 refuse after drand has been fetched: the committed
    # entries no longer hash to the stored entry_hash.
    defp break_entry_hash!(draw) do
      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET entry_hash = $2 WHERE id = $1", [
          dump(draw.id),
          String.duplicate("0", 64)
        ])
      end)
    end

    # Makes the database refuse the completion with an existing constraint,
    # no DDL: an execution receipt already stored for the draw collides with
    # the unique index on execution_receipts(draw_id) when execution
    # inserts its own.
    defp occupy_execution_receipt!(draw) do
      with_triggers_off(fn ->
        Repo.query!(
          """
          INSERT INTO execution_receipts (id, draw_id, operator_id, sequence, lock_receipt_hash,
            payload_jcs, signature, signing_key_id)
          VALUES ($1, $2, $3, $4, 'x', '{}', $5, 'k')
          """,
          [
            dump(Ecto.UUID.generate()),
            dump(draw.id),
            dump(draw.operator_id),
            draw.operator_sequence + 1_000_000,
            :binary.copy(<<0>>, 64)
          ]
        )
      end)
    end

    defp delete_jobs_for!(draw),
      do: Repo.query!("DELETE FROM oban_jobs WHERE args->>'draw_id' = $1", [draw.id])

    @tag :pending_task_10
    test "INV-9 an execute error after the fetch leaves the draw pending, on every attempt" do
      draw = v6_draw(-(@w + 60), -10)
      break_entry_hash!(draw)

      for attempt <- [1, 10] do
        perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)
        assert_fetched(draw)
        assert reload(draw).status == :pending_entropy, "attempt #{attempt}"
      end
    end

    @tag :pending_task_10
    test "INV-9 a database refusal after the fetch leaves the draw pending, on every attempt" do
      draw = v6_draw(-(@w + 60), -10)
      occupy_execution_receipt!(draw)

      for attempt <- [1, 10] do
        perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)
        assert_fetched(draw)
        assert reload(draw).status == :pending_entropy, "attempt #{attempt}"
      end
    end

    @tag :pending_task_10
    test "INV-9 the forecast worker, handed a v6 draw, never fails it either" do
      draw = v6_draw(-(@w + 60), -10)
      break_entry_hash!(draw)

      perform_job(EntropyWorker, %{draw_id: draw.id}, attempt: 10)
      assert_fetched(draw)
      assert reload(draw).status == :pending_entropy
    end

    @tag :pending_task_10
    test "INV-9 the draws guard refuses failing a v6 draw whose drand is stored" do
      draw = v6_draw(-(@w + 60), -10) |> to_pending!()

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET drand_randomness = $2 WHERE id = $1", [
          dump(draw.id),
          @randomness
        ])
      end)

      assert try_sql(
               "UPDATE draws SET status = 'failed', failed_at = now() WHERE id = $1",
               [dump(draw.id)]
             ) == @no_fail_after_drand

      # Positive control: a forecast draw with drand stored still fails as
      # before; the backstop is a no-op without the v6 pair.
      forecast = create_draw(create_api_key())

      with_triggers_off(fn ->
        Repo.query!(
          "UPDATE draws SET status = 'pending_entropy', drand_randomness = $2 WHERE id = $1",
          [dump(forecast.id), @randomness]
        )
      end)

      assert try_sql(
               "UPDATE draws SET status = 'failed', failed_at = now() WHERE id = $1",
               [dump(forecast.id)]
             ) == nil
    end

    @tag :pending_task_10
    test "INV-9 before drand is fetched, drand exhaustion still fails the draw" do
      # Positive control for the backstop: with no drand stored, failing is
      # allowed, through the worker and through a raw UPDATE.
      Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
      draw = v6_draw(-(@w + 60), -10)

      perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)
      failed = reload(draw)
      assert failed.status == :failed
      assert failed.drand_randomness == nil

      other = v6_draw(-(@w + 60), -10) |> to_pending!()

      assert try_sql(
               "UPDATE draws SET status = 'failed', failed_at = now() WHERE id = $1",
               [dump(other.id)]
             ) == nil
    end

    @tag :pending_task_10
    @tag :pending_task_18
    test "INV-9 a discarded job is re-driven, and the draw is still not failed" do
      # Stuck: pub(R) more than 15 minutes ago, and no live job.
      draw = v6_draw(-(@w + 3600), -20 * 60)
      break_entry_hash!(draw)

      perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)
      assert_fetched(draw)
      assert reload(draw).status == :pending_entropy
      delete_jobs_for!(draw)

      assert draw.id in StuckDrawRedriver.redrive()
      assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
      assert reload(draw).status == :pending_entropy
    end
  end

  # ── INV-10 ────────────────────────────────────────────────────────

  defp lock_at(draw, key, draw_at),
    do: draw |> Ash.Changeset.for_update(:lock, %{draw_at: draw_at}, actor: key) |> Ash.update()

  defp set_protocol!(operator, protocol) do
    {:ok, operator} =
      operator
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: protocol})
      |> Ash.update(authorize?: false)

    operator
  end

  describe "INV-10 an operator flag flip after lock never changes a locked draw's protocol" do
    # Live now: the database freezes the pair once a draw leaves open.
    test "INV-10 the stored pair can't be changed after the lock, by any UPDATE" do
      {_op, key} = create_v6_operator()
      s = in_time_schedule()
      v6 = open_draw_with_entries(key)
      assert raw_lock(v6, s.weather_time, s.round) == nil
      forecast = create_draw(create_api_key())
      frozen = "lock_schema_version and entropy_composition are frozen once a draw has left open"

      for {draw, sql} <- [
            {v6,
             "UPDATE draws SET lock_schema_version = NULL, entropy_composition = NULL WHERE id = $1"},
            {v6,
             "UPDATE draws SET entropy_composition = 'drand-quicknet+metoffice-landobs-v2' WHERE id = $1"},
            {forecast,
             "UPDATE draws SET lock_schema_version = '6', entropy_composition = '#{LandObs.tag()}' WHERE id = $1"}
          ] do
        assert try_sql(sql, [dump(draw.id)]) == frozen, sql
      end
    end

    @tag :pending_task_11
    test "INV-10 a v6 draw stays v6 after its operator moves to forecast" do
      ensure_infrastructure_key()
      {op, key} = create_v6_operator()

      {:ok, s} =
        Schedule.schedule(Schedule.default_draw_at(DateTime.add(DateTime.utc_now(), 3 * 3600)))

      {:ok, locked} = lock_at(open_draw_with_entries(key), key, s.draw_at)

      set_protocol!(op, :forecast)
      after_flip = reload(locked)

      assert {after_flip.lock_schema_version, after_flip.entropy_composition} ==
               {"6", LandObs.tag()}

      assert {after_flip.drand_round, after_flip.weather_time, after_flip.weather_station} ==
               {s.round, s.weather_time, Stations.primary().id}
    end

    @tag :pending_task_11
    test "INV-10 a forecast draw stays forecast after its operator moves to observation" do
      ensure_infrastructure_key()
      {op, key} = create_v6_operator()
      set_protocol!(op, :forecast)

      {:ok, locked} =
        open_draw_with_entries(key)
        |> Ash.Changeset.for_update(:lock, %{}, actor: key)
        |> Ash.update()

      set_protocol!(op, :observation)
      after_flip = reload(locked)
      assert {after_flip.lock_schema_version, after_flip.entropy_composition} == {nil, nil}
      assert after_flip.expected_result_at == nil
    end
  end

  # ── INV-11 ────────────────────────────────────────────────────────

  describe "INV-11 a draw's expected_result_at is fixed at lock and never changes" do
    # Live now: drand_round and the pair are frozen once a draw leaves open,
    # and expected_result_at derives from nothing else.
    test "INV-11 the fields expected_result_at derives from are frozen after the lock" do
      {_op, key} = create_v6_operator()
      s = in_time_schedule()
      draw = open_draw_with_entries(key)
      assert raw_lock(draw, s.weather_time, s.round) == nil
      assert reload(draw).expected_result_at == s.expected_result_at

      assert try_sql("UPDATE draws SET drand_round = drand_round + 1 WHERE id = $1", [
               dump(draw.id)
             ]) == "Cannot modify declared entropy fields"

      pending =
        reload(draw)
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(authorize?: false)

      assert reload(pending).expected_result_at == s.expected_result_at
    end

    @tag :pending_task_11
    test "INV-11 expected_result_at survives a flag flip and the move to pending" do
      ensure_infrastructure_key()
      {op, key} = create_v6_operator()

      {:ok, s} =
        Schedule.schedule(Schedule.default_draw_at(DateTime.add(DateTime.utc_now(), 3 * 3600)))

      {:ok, locked} = lock_at(open_draw_with_entries(key), key, s.draw_at)
      assert reload(locked).expected_result_at == s.expected_result_at

      set_protocol!(op, :forecast)
      assert reload(locked).expected_result_at == s.expected_result_at

      locked
      |> Ash.Changeset.for_update(:transition_to_pending, %{})
      |> Ash.update!(authorize?: false)

      assert reload(locked).expected_result_at == s.expected_result_at
    end
  end
end
