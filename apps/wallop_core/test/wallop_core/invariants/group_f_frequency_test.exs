defmodule WallopCore.Invariants.FrequencyTest do
  @moduledoc """
  Group F: the protocol invariants of the grid-frequency tag
  (`drand-quicknet+elexon-freq-v1`, lock schema 6 / execution schema 5).
  Each is written now and tagged `:pending_task_F<n>`; its task removes the
  tag and fills in the body. See `WallopCore.Invariants.SuiteTest` for the
  suite's rules.
  """
  use WallopCore.InvariantCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  @moduletag :invariant

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, ObservationDrawWorker, V6Rules}
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Frequency.Windows
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Resources.Draw

  import WallopCore.UnboxedHelpers

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
  # The draws guard's refusal, and its commit-time twin's, from F on.
  @no_fail_after_f "a v6 draw can't fail once its fetch deadline has passed"
  @other "50012;50018;50012;49983;49980;49953;49912;49884"

  defp freq_pending(key, t, pub_offset) do
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), pub_offset))
    draw = put_freq_awaiting!(open_draw_with_entries(key), t, round)
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    draw
  end

  defp complete(draw, executed_at, set_sql, params),
    do:
      try_sql(
        "UPDATE draws SET status = 'completed', executed_at = $2, #{set_sql} WHERE id = $1",
        [dump(draw.id), DateTime.to_naive(executed_at) | params]
      )

  defp pub(draw), do: Quicknet.pub_time(draw.drand_round)

  test "INV-F1 one write-once window per T; every draw of T completes with it or the fallback" do
    {_op, key} = create_freq_operator()
    # T's window is open now (now - T in [165, 180)).
    t = aligned_freq_start(-(FreqSchedule.span_seconds() + 60))
    [a, b, c] = for _ <- 1..3, do: freq_pending(key, t, 3600)

    assert {:ok, _} = Windows.store(t, @value, elexon_body(t, @value))
    assert {:error, _} = Windows.store(t, @other, elexon_body(t, @other))
    assert {:error, _} = Windows.store(t, @value, elexon_body(t, @value))

    assert db_refused?("DELETE FROM frequency_windows WHERE freq_start = $1", [
             DateTime.to_naive(t)
           ])

    assert db_refused?("UPDATE frequency_windows SET value = $2 WHERE freq_start = $1", [
             DateTime.to_naive(t),
             @other
           ])

    for draw <- [a, b, c] do
      assert Windows.for_draw(draw).value == @value

      assert complete(draw, pub(draw), "freq_value = $3", [@other]) ==
               "v6 draw must complete with its stored frequency window"

      assert complete(draw, pub(draw), "freq_fallback_reason = $3", ["no_frequency_by_deadline"]) ==
               "v6 draw must complete with its stored frequency window"

      assert complete(draw, pub(draw), "freq_value = $3", [@value]) == nil
    end
  end

  test "INV-F2 completion equals the stored window or the fallback rule, and executed_at >= pub(R)" do
    {_op, key} = create_freq_operator()
    # F + M passed a minute ago.
    late =
      aligned_freq_start(
        -(FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() + 15 + 60)
      )

    d = freq_pending(key, late, -10)

    assert complete(d, DateTime.add(pub(d), -1, :microsecond), "freq_fallback_reason = $3", [
             "no_frequency_by_deadline"
           ]) ==
             "v6 draw cannot complete before its drand round publishes"

    assert complete(d, pub(d), "freq_value = $3", [@value]) ==
             "v6 draw may fall back only after the fetch deadline with nothing stored"

    assert complete(d, pub(d), "freq_fallback_reason = $3", ["no_observation_by_deadline"]) ==
             "v6 draw may fall back only after the fetch deadline with nothing stored"

    assert complete(d, pub(d), "freq_fallback_reason = $3, weather_value = $4", [
             "no_frequency_by_deadline",
             "141;1025;85;2432"
           ]) ==
             "a grid-frequency draw carries no weather fields"

    assert complete(d, pub(d), "freq_fallback_reason = $3", ["no_frequency_by_deadline"]) == nil
  end

  test "INV-F3 no fallback until F + M, and no fail from F" do
    {_op, key} = create_freq_operator()
    # A stored freq_start whose F was 5 s ago: past F, not yet past F + M.
    t =
      DateTime.utc_now()
      |> DateTime.add(-(FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() + 5))
      |> DateTime.truncate(:second)

    d = freq_pending(key, t, -10)

    assert complete(d, pub(d), "freq_fallback_reason = $3", ["no_frequency_by_deadline"]) ==
             "v6 draw may fall back only after the fetch deadline with nothing stored"

    assert try_sql("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
             dump(d.id),
             NaiveDateTime.utc_now()
           ]) ==
             "a v6 draw can't fail once its fetch deadline has passed"

    # Before F, failing is still a visible abort and is allowed.
    early = freq_pending(key, aligned_freq_start(-(FreqSchedule.span_seconds() + 60)), 3600)

    assert try_sql("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
             dump(early.id),
             NaiveDateTime.utc_now()
           ]) == nil
  end

  @tag :slow
  test "INV-F3 a window inserted before F and committed after F is refused at commit" do
    {operator, key} = unboxed(fn -> create_freq_operator() end)
    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)

    now = DateTime.to_unix(DateTime.utc_now())
    lead = FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() - 3

    t =
      DateTime.from_unix!((now - lead + Integer.mod(-(now - lead), 15)) * 1_000_000, :microsecond)

    unboxed(fn -> freq_pending(key, t, 3600) end)

    outcome =
      unboxed(fn ->
        try do
          # F is up to 18 s away, past the default 15 s transaction timeout.
          {:ok, _} =
            Repo.transaction(
              fn ->
                Repo.query!(
                  "INSERT INTO frequency_windows (id, freq_start, value, raw) VALUES (gen_random_uuid(), $1, $2, '{}')",
                  [DateTime.to_naive(t), @value]
                )

                wait_until_db_clock_after(FreqSchedule.fetch_deadline(t))
              end,
              timeout: 60_000
            )

          :committed
        rescue
          e in Postgrex.Error -> {:refused, e.postgres.message}
        end
      end)

    assert outcome == {:refused, "a frequency window must commit by its fetch deadline"}
    assert unboxed(fn -> Windows.for_start(t) end) == nil
  end

  test "INV-F4 the signed freq_start, locked_at, drand_round and drand_chain equal the row, in either order" do
    {_op, key} = create_freq_operator()
    s = in_time_freq_schedule()
    late = DateTime.add(FreqSchedule.latest_lock_at(s.freq_start), 1, :microsecond)

    cases = [
      {"freq_start", &Map.put(&1, "freq_start", rfc(DateTime.add(s.freq_start, 15))), & &1,
       "v6 lock receipt field freq_start does not match the draw"},
      {"locked_at", &Map.put(&1, "locked_at", rfc(late)), &%{&1 | locked_at: late},
       "v6 signed locked_at is too late for this draw time"},
      {"drand_round", &Map.put(&1, "drand_round", s.round + 1), & &1,
       "v6 lock receipt field drand_round does not match the draw"},
      {"drand_chain", &Map.put(&1, "drand_chain", String.duplicate("0", 64)), & &1,
       "v6 lock receipt field drand_chain does not match the draw"}
    ]

    for {field, tamper, cols_for, message} <- cases, order <- [:after_lock, :before_lock] do
      draw = open_draw_with_entries(key)
      {payload, cols} = valid_freq_receipt(draw, s)
      {payload, cols} = {tamper.(payload), cols_for.(cols)}

      refusal =
        case order do
          :after_lock ->
            nil = raw_freq_lock(draw, s)
            insert_receipt(payload, cols)

          :before_lock ->
            with_triggers_off(fn -> keep_receipt!(payload, cols) end)
            raw_freq_lock(draw, s)
        end

      assert refusal == message, "#{field}, receipt #{order}"
    end
  end

  test "INV-F4 through the real lock: the signed freq_start, locked_at, drand_round and drand_chain equal the row" do
    ensure_infrastructure_key()
    {_op, key} = create_freq_operator()
    s = in_time_freq_schedule()

    {:ok, locked} =
      open_draw_with_entries(key)
      |> Ash.Changeset.for_update(:lock, %{draw_at: s.draw_at}, actor: key)
      |> Ash.update()

    locked = Ash.load!(locked, [:receipt], authorize?: false)
    p = Jason.decode!(locked.receipt.payload_jcs)

    assert p["freq_start"] == rfc(locked.freq_start)
    assert locked.freq_start == FreqSchedule.freq_start_for_round(locked.drand_round)
    assert p["locked_at"] == rfc(locked.receipt.locked_at)
    assert FreqSchedule.lock_allowed?(locked.receipt.locked_at, locked.freq_start)
    assert {p["drand_round"], p["drand_chain"]} == {locked.drand_round, locked.drand_chain}
    assert {p["drand_round"], p["entropy_composition"]} == {s.round, Freq.tag()}
  end

  test "INV-F5 SQL frequency timing equals Elixir under a non-UTC session" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")

    for round <- [1, 33_068_211, 33_068_212, 33_068_213, 33_068_217, 90_000_000] do
      t = FreqSchedule.freq_start_for_round(round)

      %{rows: [[sql_t, sql_f, at_gap, past_gap]]} =
        Repo.query!(
          """
          SELECT wallop_freq_start($1), wallop_freq_fetch_deadline(wallop_freq_start($1)),
                 wallop_freq_lock_allowed($2, wallop_freq_start($1)),
                 wallop_freq_lock_allowed($3, wallop_freq_start($1))
          """,
          [
            round,
            DateTime.to_naive(FreqSchedule.latest_lock_at(t)),
            DateTime.to_naive(DateTime.add(FreqSchedule.latest_lock_at(t), 1, :microsecond))
          ]
        )

      assert DateTime.from_naive!(sql_t, "Etc/UTC") == t
      assert DateTime.from_naive!(sql_f, "Etc/UTC") == FreqSchedule.fetch_deadline(t)
      assert {at_gap, past_gap} == {true, false}
    end
  end

  test "INV-F6 an unknown (schema, tag) pair is refused everywhere; frequency never falls through to Land Obs" do
    unknown = "drand-quicknet+elexon-freq-v2"

    # Builders.
    lock = %{
      entropy_composition: unknown,
      operator_id: Ecto.UUID.generate(),
      operator_slug: "acme-prizes",
      sequence: 1,
      draw_id: Ecto.UUID.generate(),
      commitment_hash: String.duplicate("ab", 32),
      entry_hash: String.duplicate("ab", 32),
      locked_at: ~U[2026-10-14 19:50:00.000000Z],
      signing_key_id: "k",
      winner_count: 1,
      drand_chain: Quicknet.chain_hash(),
      drand_round: 33_068_212,
      weather_station: nil,
      weather_time: nil,
      freq_start: ~U[2026-10-14 19:54:00.000000Z],
      wallop_core_version: "0.0.0",
      fair_pick_version: "0.2.0"
    }

    assert_raise ArgumentError, fn -> Protocol.build_v6_lock_payload(lock) end

    # Execution rules: nothing falls through.
    for {schema, tag} = pair <- [{"6", unknown}, {"5", Freq.tag()}, {nil, Freq.tag()}] do
      assert V6Rules.rules(%{lock_schema_version: schema, entropy_composition: tag}) == :error,
             inspect(pair)
    end

    assert V6Rules.rules(%{lock_schema_version: "6", entropy_composition: Freq.tag()}) ==
             {:ok, :freq}

    assert V6Rules.rules(%{lock_schema_version: "6", entropy_composition: LandObs.tag()}) ==
             {:ok, :landobs}

    # Triggers: the draws guard refuses the pair at lock.
    {_op, key} = create_freq_operator()

    assert raw_freq_lock(open_draw_with_entries(key), in_time_freq_schedule(), tag: unknown) ==
             "unknown lock_schema_version and entropy_composition pair: (6, #{unknown})"

    # Execution: a draw stored under the pair (triggers off) is refused and
    # cancelled, never run.
    ensure_infrastructure_key()
    draw = open_draw_with_entries(key)
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -60))

    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = 'pending_entropy', lock_schema_version = '6',
          entropy_composition = $2, drand_chain = $3, drand_round = $4, freq_start = $5
        WHERE id = $1
        """,
        [
          dump(draw.id),
          unknown,
          Quicknet.chain_hash(),
          round,
          DateTime.to_naive(FreqSchedule.freq_start_for_round(round))
        ]
      )
    end)

    assert {:cancel, message} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    assert message =~ "unknown lock_schema_version and entropy_composition pair"
    assert Ash.get!(Draw, draw.id, authorize?: false).status == :pending_entropy
  end

  test "INV-F7 a grid-frequency draw is never marked failed once its F has passed" do
    ensure_infrastructure_key()

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
    Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

    {_op, key} = create_freq_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))

    draw =
      put_freq_awaiting!(
        open_draw_with_entries(key),
        FreqSchedule.freq_start_for_round(round),
        round
      )

    # The worker: drand down on the last attempt is an error for the
    # re-drive, never a failure.
    assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)
    status = Ash.get!(Draw, draw.id, authorize?: false).status
    assert status in [:awaiting_entropy, :pending_entropy]

    # The database: failing it now is refused, by any path.
    assert try_sql("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
             dump(draw.id),
             NaiveDateTime.utc_now()
           ]) ==
             @no_fail_after_f

    assert {:error, error} =
             draw
             |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "test"})
             |> Ash.update(authorize?: false)

    assert error_text(error) =~ @no_fail_after_f
  end

  # The commit-time half: a fail whose statement runs before F passes the
  # statement check; its commit waits until F has passed and the deferred
  # check (which reads F by tag) refuses it. Real commits, outside the
  # sandbox, on fixtures this test deletes.
  @tag :slow
  test "INV-F7 a grid-frequency fail made before F but committed after it is refused at commit" do
    draw = unboxed_freq_draw(4)
    f = FreqSchedule.fetch_deadline(draw.freq_start)

    outcome =
      fail_and_commit(draw, fn ->
        assert DateTime.compare(db_clock(), f) == :lt
        wait_until_db_clock_after(f)
      end)

    assert outcome == {:refused, @no_fail_after_f}

    assert unboxed(fn -> Ash.get!(Draw, draw.id, authorize?: false).status end) ==
             :awaiting_entropy
  end

  @tag :slow
  test "INV-F7 a grid-frequency fail committed before F is kept" do
    # Positive control: same path, F five minutes ahead, commit at once.
    draw = unboxed_freq_draw(300)

    assert fail_and_commit(draw, fn -> :ok end) == :committed
    assert unboxed(fn -> Ash.get!(Draw, draw.id, authorize?: false).status end) == :failed
  end

  # A grid-frequency draw committed outside the sandbox, whose stored F is
  # `f_in` seconds from now, for its own operator, deleted on exit.
  #
  # The stored freq_start is deliberately not the round's window start: the
  # round publishes an hour from now, so F derived from the round would be
  # far ahead. Only F read from the stored freq_start (as the guard and its
  # commit-time twin do, through wallop_v6_fetch_deadline) is a few seconds
  # away, so the straddle tells "F from freq_start" apart from "F from the
  # round".
  defp unboxed_freq_draw(f_in) do
    {operator, key} = unboxed(fn -> create_freq_operator() end)
    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)

    t =
      DateTime.utc_now()
      |> DateTime.add(f_in - FreqSchedule.span_seconds() - FreqSchedule.fetch_window_seconds())
      |> DateTime.truncate(:second)

    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))
    unboxed(fn -> put_freq_awaiting!(open_draw_with_entries(key), t, round) end)
  end

  # Fails the draw in a real transaction, runs `before_commit` inside it,
  # then commits. :committed, or {:refused, message}.
  defp fail_and_commit(draw, before_commit) do
    unboxed(fn ->
      {:ok, _} =
        Repo.transaction(
          fn ->
            Repo.query!("SET LOCAL lock_timeout = '10s'")

            Repo.query!("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
              dump(draw.id),
              NaiveDateTime.utc_now()
            ])

            before_commit.()
          end,
          timeout: 60_000
        )
    end)

    :committed
  rescue
    e in Postgrex.Error -> {:refused, e.postgres.message}
  end

  defp db_clock do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")
    DateTime.from_naive!(now, "Etc/UTC")
  end
end
