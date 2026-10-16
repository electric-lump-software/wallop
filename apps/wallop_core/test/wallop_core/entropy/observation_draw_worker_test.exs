defmodule WallopCore.Entropy.ObservationDrawWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, EntropyWorker, ObservationDrawWorker}
  alias WallopCore.Protocol
  alias WallopCore.Resources.{Draw, ExecutionReceipt}
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  require Ash.Query

  @w Schedule.fetch_window_seconds()
  @value "141;1025;85;2432"
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"

  setup do
    ensure_infrastructure_key()
    test_pid = self()

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    # Echoes the requested round, so the client's round check passes, and
    # reports each fetch to the test.
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

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  # A v6 draw whose fetch window closed `closed_ago` seconds ago (on the
  # stored weather_time) and whose drand round publishes `pub_offset`
  # seconds from now.
  defp v6_draw_after_deadline(closed_ago, pub_offset \\ -10) do
    {op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-(@w + closed_ago)) |> DateTime.truncate(:second)
    {op, put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(pub_offset))}
  end

  # A v6 draw as a real lock leaves it: weather_time is the round's own
  # observation hour. The round published 10 seconds ago, so F has passed.
  # A reading from `station` is stored for the hour.
  defp v6_draw_on_round_hour(station) do
    {_op, key} = create_v6_operator()
    round = round_at(-10)
    wt = Schedule.weather_time_for_round(round)
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    put_observation!(station, wt, @value)
    draw
  end

  defp reload(d), do: Ash.get!(Draw, d.id, authorize?: false)

  defp exec_payload(draw) do
    %{execution_receipt: receipt} = Ash.load!(reload(draw), :execution_receipt, authorize?: false)
    Jason.decode!(receipt.payload_jcs)
  end

  defp execution_receipt_count(draw) do
    id = draw.id

    ExecutionReceipt
    |> Ash.Query.filter(draw_id == ^id)
    |> Ash.count!(authorize?: false)
  end

  defp set_lock_receipt_fair_pick!(draw, version) do
    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE operator_receipts
        SET payload_jcs = convert_to(
          regexp_replace(convert_from(payload_jcs, 'UTF8'),
            '"fair_pick_version":"[^"]*"', '"fair_pick_version":"' || $2 || '"'), 'UTF8')
        WHERE draw_id = $1
        """,
        [Ecto.UUID.dump!(draw.id), version]
      )
    end)
  end

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  describe "executing by rule" do
    test "no observation stored by F: drand-only by rule, exec schema 5 naming the primary" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :executed]])
      {_op, draw} = v6_draw_after_deadline(60)
      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})

      done = reload(draw)
      assert done.status == :completed
      assert done.weather_value == nil
      assert done.weather_observation_time == nil
      assert done.weather_fallback_reason == "no_observation_by_deadline"
      assert done.drand_randomness == @randomness
      assert done.weather_station == Stations.primary().id

      {seed, _} = Protocol.compute_seed(done.entry_hash, @randomness)
      assert done.seed == Base.encode16(seed, case: :lower)

      payload = exec_payload(draw)
      assert payload["schema_version"] == "5"
      assert payload["entropy_composition"] == Protocol.landobs_entropy_composition()
      assert payload["weather_station"] == "wmo-03749"
      assert payload["weather_value"] == nil
      assert payload["weather_fallback_reason"] == "no_observation_by_deadline"

      assert_receive {[:wallop_core, :v6, :executed], ^ref, _, %{station: nil, fallback?: true}}
    end

    for station <- [Stations.primary().id, Stations.backup().id] do
      @station station
      test "a stored reading (#{station}) is used, and the receipt names its station" do
        ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :executed]])
        draw = v6_draw_on_round_hour(@station)
        assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})

        done = reload(draw)
        assert done.status == :completed
        assert done.weather_value == @value
        assert done.weather_observation_time == draw.weather_time
        assert done.weather_fallback_reason == nil
        # The draws row keeps the lock's station; the receipt names the one used.
        assert done.weather_station == Stations.primary().id

        {seed, _} = Protocol.compute_seed(done.entry_hash, @randomness, @value)
        assert done.seed == Base.encode16(seed, case: :lower)

        payload = exec_payload(draw)
        assert payload["schema_version"] == "5"
        assert payload["weather_station"] == @station
        assert payload["weather_value"] == @value
        assert payload["weather_fallback_reason"] == nil

        assert_receive {[:wallop_core, :v6, :executed], ^ref, _,
                        %{station: @station, fallback?: false}}
      end
    end

    test "dispatch follows the stored version, not the operator's current flag" do
      {op, draw} = v6_draw_after_deadline(60)

      {:ok, _} =
        op
        |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :forecast})
        |> Ash.update(authorize?: false)

      # EntropyWorker hands a v6 draw to the v6 executor.
      assert :ok = perform_job(EntropyWorker, %{draw_id: draw.id})
      done = reload(draw)
      assert done.status == :completed
      assert done.weather_fallback_reason == "no_observation_by_deadline"
      assert exec_payload(draw)["schema_version"] == "5"
    end

    test "a completed draw is left alone" do
      {_op, draw} = v6_draw_after_deadline(60)
      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      assert_received {:drand_fetched, _}

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      refute_received {:drand_fetched, _}
    end
  end

  describe "waiting" do
    test "while the window is open the worker waits rather than deciding" do
      {_op, key} = create_v6_operator()
      wt = DateTime.utc_now() |> DateTime.add(-(@w - 5 * 60)) |> DateTime.truncate(:second)
      draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(-10))

      {:ok, _} =
        Observations.store(Stations.backup().id, %{
          value: "90;1025;85;2432",
          raw: "[]",
          observation_time: wt
        })

      assert {:snooze, secs} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      assert secs in 290..302
      assert reload(draw).status == :awaiting_entropy
      refute_received {:drand_fetched, _}
    end

    test "F < now < pub(R): the worker waits for the round" do
      {_op, draw} = v6_draw_after_deadline(60, 600)
      assert {:snooze, secs} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      assert secs >= 590
      assert reload(draw).status == :awaiting_entropy
      refute_received {:drand_fetched, _}
    end
  end

  describe "which draws it runs" do
    test "a forecast draw is cancelled by the v6 worker, untouched" do
      draw = create_draw(create_api_key())
      assert draw.lock_schema_version == nil
      assert {:cancel, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      assert reload(draw).status == :awaiting_entropy
      refute_received {:drand_fetched, _}
    end

    test "a missing draw ends the job" do
      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: Ash.UUID.generate()})
    end

    test "unique among live jobs only, so a cancelled job can be inserted again" do
      {_op, draw} = v6_draw_after_deadline(60)
      {:ok, first} = Oban.insert(ObservationDrawWorker.new(%{draw_id: draw.id}))
      {:ok, again} = Oban.insert(ObservationDrawWorker.new(%{draw_id: draw.id}))
      assert again.conflict?
      assert again.id == first.id

      for state <- ~w(cancelled discarded completed) do
        Repo.query!("UPDATE oban_jobs SET state = $2 WHERE args->>'draw_id' = $1", [
          draw.id,
          state
        ])

        {:ok, next} = Oban.insert(ObservationDrawWorker.new(%{draw_id: draw.id}))
        refute next.conflict?, state
        Repo.query!("DELETE FROM oban_jobs WHERE id = $1", [next.id])
      end
    end
  end

  describe "failures" do
    test "drand unavailable on the last attempt fails the draw; earlier attempts retry" do
      {_op, draw} = v6_draw_after_deadline(60)
      Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)
      failed = reload(draw)
      assert failed.status == :failed
      assert failed.drand_randomness == nil
    end

    test "a failure after drand is fetched never fails the draw, even on the last attempt" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :execute_error]])
      {_op, draw} = v6_draw_after_deadline(60)

      # Make execute_v6 refuse (entry hash mismatch) after drand has been fetched.
      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET entry_hash = $2 WHERE id = $1", [
          Ecto.UUID.dump!(draw.id),
          String.duplicate("0", 64)
        ])
      end)

      for attempt <- [1, 10] do
        assert {:error, _} =
                 perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)

        assert_received {:drand_fetched, _}
        assert reload(draw).status == :pending_entropy
        assert_receive {[:wallop_core, :v6, :execute_error], ^ref, _, %{draw_id: id}}
        assert id == draw.id
      end
    end

    test "a receipt the builder refuses on stored state: exec_refused, job cancelled, draw untouched" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])

      # A reading stored for a weather_time that isn't the round's hour: the
      # draws guard would accept the completion, but the exec v5 builder
      # refuses an observation time that isn't the round's whole hour. No retry can fix
      # stored state, so the job stops at once.
      {_op, draw} = v6_draw_after_deadline(60)
      put_observation!(Stations.backup().id, draw.weather_time, @value)

      assert {:cancel, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)

      assert reason =~ "weather_observation_time"
      assert_received {:drand_fetched, _}

      left = reload(draw)
      assert left.status == :pending_entropy
      assert left.drand_randomness == nil
      assert execution_receipt_count(draw) == 0

      assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, %{draw_id: id, reason: msg}}
      assert id == draw.id
      assert msg =~ "weather_observation_time"
    end

    test "a lock receipt with another fair_pick_version: refused before signing" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])
      {_op, draw} = v6_draw_after_deadline(60)
      set_lock_receipt_fair_pick!(draw, "0.1.0")

      assert {:cancel, reason} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      assert reason =~ "fair_pick_version"
      assert reload(draw).status == :pending_entropy
      assert execution_receipt_count(draw) == 0
      assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, %{reason: msg}}
      assert msg =~ "differs from the lock receipt's \"0.1.0\""
    end

    test "an unknown stored pair is refused before drand is fetched, and never fails the draw" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])
      {_op, draw} = v6_draw_after_deadline(60)
      other = "drand-quicknet+metoffice-landobs-v2"

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET entropy_composition = $2 WHERE id = $1", [
          Ecto.UUID.dump!(draw.id),
          other
        ])
      end)

      for worker <- [ObservationDrawWorker, EntropyWorker] do
        assert {:cancel, reason} = perform_job(worker, %{draw_id: draw.id}, attempt: 10)
        assert reason =~ "unknown lock_schema_version and entropy_composition pair: (6, #{other})"
        assert reload(draw).status == :awaiting_entropy
        assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, _}
      end

      refute_received {:drand_fetched, _}
    end
  end
end
