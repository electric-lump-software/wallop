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
              WallopCore.Weather.Observations,
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

  defp reading(draw, value \\ @value),
    do: %{value: value, raw: "[]", observation_time: draw.weather_time}

  defp complete(draw, set_sql, params \\ []) do
    try_sql(
      "UPDATE draws SET status = 'completed', executed_at = $2, #{set_sql} WHERE id = $1",
      [dump(draw.id), NaiveDateTime.utc_now() | params]
    )
  end

  # Moves a draw's stored window, and its observation, an hour into the past
  # with every trigger off, so "after F" holds while the stored row stays.
  defp shift_window_back!(draw) do
    with_triggers_off(fn ->
      Repo.query!(
        "UPDATE draws SET weather_time = weather_time - interval '1 hour' WHERE id = $1",
        [dump(draw.id)]
      )

      Repo.query!(
        "UPDATE weather_observations SET observation_time = observation_time - interval '1 hour' WHERE draw_id = $1",
        [dump(draw.id)]
      )
    end)
  end

  # ── INV-7 ─────────────────────────────────────────────────────────

  describe "INV-7 one value per (station, hour), write-once" do
    @tag :pending_task_6
    test "INV-7 a second draw of the hour can't store a different value" do
      {_op, key} = create_v6_operator()
      [a, b, c] = for _ <- 1..3, do: v6_draw(-5 * 60, 3600, key)
      primary = Stations.primary().id

      assert {:ok, _} = Observations.store(a.id, primary, reading(a))
      assert {:error, _} = Observations.store(b.id, primary, reading(b, "142;1025;85;2432"))
      assert {:ok, _} = Observations.store(c.id, primary, reading(c))
    end

    @tag :pending_task_6
    test "INV-7 a draw stores one observation, from one station" do
      draw = v6_draw(-5 * 60, 3600)

      assert {:ok, _} = Observations.store(draw.id, Stations.primary().id, reading(draw))
      assert {:error, _} = Observations.store(draw.id, Stations.primary().id, reading(draw))
      assert {:error, _} = Observations.store(draw.id, Stations.backup().id, reading(draw))
    end

    @tag :pending_task_6
    test "INV-7 a stored observation can't be updated, deleted or truncated" do
      draw = v6_draw(-5 * 60, 3600)
      {:ok, _} = Observations.store(draw.id, Stations.primary().id, reading(draw))

      for sql <- [
            "UPDATE weather_observations SET value = '1;1000;1;1' WHERE draw_id = $1",
            "DELETE FROM weather_observations WHERE draw_id = $1"
          ] do
        assert try_sql(sql, [dump(draw.id)]) != nil, sql
      end

      assert try_sql("TRUNCATE weather_observations", []) != nil
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

    @tag :pending_task_6
    test "INV-8 with an observation stored, only that observation completes the draw" do
      draw = v6_draw(-(@w - 5 * 60), -10)
      {:ok, obs} = Observations.store(draw.id, Stations.backup().id, reading(draw))
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

    @tag :pending_task_6
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
      {:ok, obs} = Observations.store(draw.id, Stations.backup().id, reading(draw))
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

  describe "INV-8b a stored observation's commit time is at or before F" do
    # The sandbox wraps each test in one transaction, so a commit can't
    # happen in it. This test runs its fixtures and its store transaction
    # outside it (Sandbox.unboxed_run/2, as V6LockReceiptRaceTest does), on
    # real connections that really commit, and deletes what it created.
    @tag :pending_task_6
    test "INV-8b an insert made before F but committed after F is refused at commit" do
      # F is a few seconds ahead: the store's statement runs inside the
      # backup window, before F; its commit waits until F has passed.
      lead = 4

      {operator, draw} =
        unboxed(fn ->
          {operator, key} = create_v6_operator()
          {operator, v6_draw(-(@w - lead), 3600, key)}
        end)

      on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
      f = Schedule.fetch_deadline(draw.weather_time)

      outcome =
        try do
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL lock_timeout = '10s'")
              {:ok, _} = Observations.store(draw.id, Stations.backup().id, reading(draw))
              assert DateTime.compare(DateTime.utc_now(), f) == :lt
              Process.sleep(max(DateTime.diff(f, DateTime.utc_now(), :millisecond), 0) + 1_000)
            end)
          end)
        rescue
          e in Postgrex.Error -> {:refused, e.postgres.message}
        end

      assert match?({:refused, _}, outcome), inspect(outcome)

      assert unboxed(fn ->
               Repo.query!("SELECT count(*) FROM weather_observations WHERE draw_id = $1", [
                 dump(draw.id)
               ]).rows
             end) == [[0]]
    end
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
        do: Repo.query!("DELETE FROM weather_observations WHERE draw_id IN (#{draws})", [id])

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

  describe "INV-9 after drand is fetched, a v6 draw is never marked failed" do
    setup do
      ensure_infrastructure_key()

      Application.put_env(:wallop_core, DrandClient,
        req_options: [plug: {Req.Test, DrandClient}, retry: false]
      )

      Req.Test.stub(DrandClient, fn conn ->
        Req.Test.json(conn, %{
          "round" => 1,
          "randomness" => @randomness,
          "signature" => String.duplicate("ab", 48)
        })
      end)

      on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
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

    # Makes the database refuse the completion, inside this test's
    # transaction only (rolled back with it).
    defp refuse_completion_in_db!(draw) do
      Repo.query!("""
      CREATE FUNCTION inv9_refuse_completion() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'test: completion refused'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER inv9_refuse BEFORE UPDATE ON draws FOR EACH ROW
        WHEN (NEW.status = 'completed' AND NEW.id = '#{draw.id}')
        EXECUTE FUNCTION inv9_refuse_completion()
      """)
    end

    @tag :pending_task_10
    test "INV-9 an execute error after the fetch leaves the draw pending, on every attempt" do
      draw = v6_draw(-(@w + 60), -10)
      break_entry_hash!(draw)

      for attempt <- [1, 10] do
        perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)
        assert reload(draw).status == :pending_entropy, "attempt #{attempt}"
      end
    end

    @tag :pending_task_10
    test "INV-9 a database refusal after the fetch leaves the draw pending, on every attempt" do
      draw = v6_draw(-(@w + 60), -10)
      refuse_completion_in_db!(draw)

      for attempt <- [1, 10] do
        perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)
        assert reload(draw).status == :pending_entropy, "attempt #{attempt}"
      end
    end

    @tag :pending_task_10
    test "INV-9 the forecast worker, handed a v6 draw, never fails it either" do
      draw = v6_draw(-(@w + 60), -10)
      break_entry_hash!(draw)

      perform_job(EntropyWorker, %{draw_id: draw.id}, attempt: 10)
      refute reload(draw).status == :failed
    end

    @tag :pending_task_10
    @tag :pending_task_18
    test "INV-9 a discarded job is re-driven, and the draw is still not failed" do
      # Stuck: pub(R) more than 15 minutes ago, and no live job.
      draw = v6_draw(-(@w + 3600), -20 * 60)
      break_entry_hash!(draw)

      perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)
      assert reload(draw).status == :pending_entropy
      Repo.query!("DELETE FROM oban_jobs")

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
