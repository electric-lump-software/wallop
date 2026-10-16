defmodule WallopCore.Entropy.ObservationDrawWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, EntropyWorker, ObservationDrawWorker, V6Execution}
  alias WallopCore.Protocol
  alias WallopCore.Resources.{Draw, ExecutionReceipt}
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  require Ash.Query

  @w Schedule.fetch_window_seconds()
  @value "141;1025;85;2432"
  # A real quicknet beacon: the randomness is sha256 of the signature.
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

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
        "signature" => @signature
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

  defp break_entry_hash!(draw) do
    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET entry_hash = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        String.duplicate("0", 64)
      ])
    end)
  end

  # The database refuses the completion with an existing constraint: an
  # execution receipt already stored for the draw collides with the unique
  # index on execution_receipts(draw_id) when execution inserts its own.
  defp occupy_execution_receipt!(draw) do
    with_triggers_off(fn ->
      Repo.query!(
        """
        INSERT INTO execution_receipts (id, draw_id, operator_id, sequence, lock_receipt_hash,
          payload_jcs, signature, signing_key_id)
        VALUES ($1, $2, $3, $4, 'x', '{}', $5, 'k')
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(draw.id),
          Ecto.UUID.dump!(draw.operator_id),
          draw.operator_sequence + 1_000_000,
          :binary.copy(<<0>>, 64)
        ]
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
    test "drand unavailable: earlier attempts retry, the last is a refusal, never a failed draw" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])
      {_op, draw} = v6_draw_after_deadline(60)
      Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}

      assert {:cancel, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (all relays failed)"
      left = reload(draw)
      assert left.status == :pending_entropy
      assert left.drand_randomness == nil
      assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, %{reason: msg}}
      assert msg =~ "drand unavailable"
    end

    test "one relay's invalid response doesn't end the attempt: the next relay is tried" do
      {_op, draw} = v6_draw_after_deadline(60)
      calls = :counters.new(1, [:atomics])

      Req.Test.stub(DrandClient, fn conn ->
        case List.last(conn.path_info) do
          # The clock skew check's request, not a fetch of the round.
          "latest" ->
            Plug.Conn.send_resp(conn, 404, "")

          last ->
            :counters.add(calls, 1, 1)
            round = String.to_integer(last)
            # The first relay answers with another round, which the client
            # rejects as invalid; the next one answers properly.
            round = if :counters.get(calls, 1) == 1, do: round + 1, else: round

            Req.Test.json(conn, %{
              "round" => round,
              "randomness" => @randomness,
              "signature" => @signature
            })
        end
      end)

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert :counters.get(calls, 1) == 2
      assert reload(draw).status == :completed
    end

    test "every relay invalid is transient: earlier attempts retry, the last is a refusal, never a failed draw" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])
      {_op, draw} = v6_draw_after_deadline(60)

      Req.Test.stub(DrandClient, fn conn ->
        Req.Test.json(conn, %{"round" => 1, "randomness" => "nope", "signature" => "ab"})
      end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}

      assert {:cancel, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (all relays failed)"
      assert reload(draw).status == :pending_entropy
      assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, _}
    end

    test "every relay's 403 is transient: retried, a refusal only on the last attempt, never a failed draw" do
      # The public relays take no credentials, so a 403 is one relay's
      # answer, not a verdict on the fetch.
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])
      {_op, draw} = v6_draw_after_deadline(60)
      Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}

      assert {:cancel, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (all relays failed)"
      assert reload(draw).status == :pending_entropy
      assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, %{reason: msg}}
      assert msg =~ "drand"
    end

    test "every relay's 404 after pub(R) is transient too" do
      {_op, draw} = v6_draw_after_deadline(60)
      Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)

      assert {:cancel, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (not_found)"
      assert reload(draw).status == :pending_entropy
    end

    test "an entry hash mismatch after the fetch is a refusal, never a retry or a failed draw" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_core, :v6, :exec_refused],
          [:wallop_core, :v6, :execute_error]
        ])

      {_op, draw} = v6_draw_after_deadline(60)
      break_entry_hash!(draw)

      for attempt <- [1, 10] do
        assert {:cancel, reason} =
                 perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)

        assert reason =~ "entry hash mismatch"
        assert_received {:drand_fetched, _}
        assert reload(draw).status == :pending_entropy

        assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, %{draw_id: id}}
        assert id == draw.id
      end

      refute_received {[:wallop_core, :v6, :execute_error], ^ref, _, _}
    end

    test "a database refusal after the fetch retries, and never fails the draw" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :execute_error]])
      {_op, draw} = v6_draw_after_deadline(60)
      occupy_execution_receipt!(draw)

      for attempt <- [1, 10] do
        assert {:error, _} =
                 perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: attempt)

        assert_received {:drand_fetched, _}
        assert reload(draw).status == :pending_entropy
        assert_receive {[:wallop_core, :v6, :execute_error], ^ref, _, %{draw_id: id}}
        assert id == draw.id
      end
    end

    test "attempt 1 fetches drand and rolls back; a drand failure on the last attempt still doesn't fail the draw" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_core, :v6, :execute_error],
          [:wallop_core, :v6, :exec_refused]
        ])

      {_op, draw} = v6_draw_after_deadline(60)

      # Attempt 1: drand is fetched, then the database refuses the completion
      # and everything rolls back. The outcome was knowable from here on.
      occupy_execution_receipt!(draw)
      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert_received {:drand_fetched, _}
      assert_receive {[:wallop_core, :v6, :execute_error], ^ref, _, _}
      assert reload(draw).drand_randomness == nil

      # The last attempt: drand is now unavailable. Failing the draw here
      # would be a selective abort; it is refused and left for the re-drive.
      Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:cancel, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable"
      assert reload(draw).status == :pending_entropy
      assert_receive {[:wallop_core, :v6, :exec_refused], ^ref, _, %{draw_id: id}}
      assert id == draw.id
    end

    test "a post-fetch not-yet snoozes on the app clock, writes nothing and reports nothing" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_core, :v6, :executed],
          [:wallop_core, :v6, :execute_error],
          [:wallop_core, :v6, :exec_refused]
        ])

      {_op, draw} = v6_draw_after_deadline(60)
      later = round_at(600)

      # Between the worker's own check and execute_v6, the stored round moves
      # 10 minutes ahead: execute_v6 reads the draw again under its row lock
      # and says "not yet", as it would for an app clock lagging the DB's.
      Req.Test.stub(DrandClient, fn conn ->
        round = conn.path_info |> List.last() |> String.to_integer()

        with_triggers_off(fn ->
          Repo.query!("UPDATE draws SET drand_round = $2 WHERE id = $1", [
            Ecto.UUID.dump!(draw.id),
            later
          ])
        end)

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature
        })
      end)

      assert {:snooze, secs} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      assert secs >= 595

      left = reload(draw)
      assert left.status == :pending_entropy
      assert left.drand_randomness == nil
      assert execution_receipt_count(draw) == 0
      refute_received {_, ^ref, _, _}
    end

    test "the not-yet wait has a margin and a floor" do
      now = DateTime.utc_now()
      assert V6Execution.not_yet_wait(DateTime.add(now, 100), now) == 102
      assert V6Execution.not_yet_wait(DateTime.add(now, 1), now) == 5
      assert V6Execution.not_yet_wait(DateTime.add(now, -30), now) == 5
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

  describe "no path to a failed draw" do
    # The v6 path must not be able to mark a draw failed: once the worker
    # runs, drand's round has published and the outcome is knowable.
    test "no v6 execution module calls mark_failed or fail_draw_with_reason" do
      lib = Path.expand("../../../lib/wallop_core", __DIR__)

      for file <- [
            "entropy/v6_execution.ex",
            "entropy/v6_rules.ex",
            "entropy/observation_draw_worker.ex",
            "resources/draw/changes/execute_v6.ex"
          ] do
        source = File.read!(Path.join(lib, file))
        refute source =~ ~r/fail_draw_with_reason|:mark_failed|mark_failed\(/, file
      end
    end
  end

  describe "clock skew alarm" do
    # Answers the round fetch as usual and drand's latest round as given.
    defp stub_latest(latest) do
      Req.Test.stub(DrandClient, fn conn ->
        round =
          case List.last(conn.path_info) do
            "latest" -> latest
            last -> String.to_integer(last)
          end

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature
        })
      end)
    end

    test "a database clock far from drand's latest round is reported, and the draw still runs" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :clock_skew]])
      {_op, draw} = v6_draw_after_deadline(60)
      # drand says its latest round published a minute ago: the database
      # clock is a minute ahead of drand (or the relay a minute behind).
      stub_latest(round_at(-60))

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :completed

      assert_receive {[:wallop_core, :v6, :clock_skew], ^ref, %{skew_ms: skew_ms}, %{draw_id: id}}

      assert id == draw.id
      assert skew_ms > 55_000
    end

    test "a database clock behind drand's latest round is reported with a negative skew" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :clock_skew]])
      {_op, draw} = v6_draw_after_deadline(60)
      stub_latest(round_at(30))

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert_receive {[:wallop_core, :v6, :clock_skew], ^ref, %{skew_ms: skew_ms}, _}
      assert skew_ms < -25_000
    end

    test "a database clock in step with drand is not reported" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :clock_skew]])
      {_op, draw} = v6_draw_after_deadline(60)
      stub_latest(round_at(-3))

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      refute_received {[:wallop_core, :v6, :clock_skew], ^ref, _, _}
    end

    test "a failed latest-round request changes nothing" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :clock_skew]])
      {_op, draw} = v6_draw_after_deadline(60)
      # The setup stub can't answer "latest": the check's request raises.
      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :completed
      refute_received {[:wallop_core, :v6, :clock_skew], ^ref, _, _}
    end
  end
end
