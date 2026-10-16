defmodule WallopCore.Invariants.FrequencyTest do
  @moduledoc """
  Group F: the protocol invariants of the grid-frequency tag
  (`drand-quicknet+elexon-freq-v1`, lock schema 6 / execution schema 5).
  Each is written now and tagged `:pending_task_F<n>`; its task removes the
  tag and fills in the body. See `WallopCore.Invariants.SuiteTest` for the
  suite's rules.
  """
  use WallopCore.InvariantCase, async: false

  @moduletag :invariant

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Frequency.Windows

  import WallopCore.UnboxedHelpers

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
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

  @tag :pending_task_F9
  test "INV-F6 an unknown (schema, tag) pair is refused everywhere; frequency never falls through to Land Obs" do
    flunk("switched on by Task F9")
  end

  @tag :pending_task_F9
  test "INV-F7 a grid-frequency draw is never marked failed once its F has passed" do
    flunk("switched on by Task F9")
  end
end
