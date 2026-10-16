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

  alias WallopCore.Frequency.Schedule, as: FreqSchedule

  @tag :pending_task_F6
  test "INV-F1 one write-once window per T; every draw of T completes with it or the fallback" do
    flunk("switched on by Task F6")
  end

  @tag :pending_task_F6
  test "INV-F2 completion equals the stored window or the fallback rule, and executed_at >= pub(R)" do
    flunk("switched on by Task F6")
  end

  @tag :pending_task_F6
  test "INV-F3 no fallback until F + M, a stored window commits by F, and no fail from F" do
    flunk("switched on by Task F6")
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
