defmodule WallopCore.Frequency.SqlFreqPropertyTest do
  use WallopCore.DataCase, async: false
  use ExUnitProperties

  alias WallopCore.Frequency.{FreqGrammar, Schedule}
  alias WallopCore.Protocol.Tags.Freq

  defp naive(dt), do: DateTime.to_naive(dt)
  defp utc(naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  property "SQL freq_start matches Schedule, in any session time zone" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")

    check all(round <- integer(1..90_000_000), max_runs: 300) do
      %{rows: [[t]]} = Repo.query!("SELECT wallop_freq_start($1)", [round])
      assert utc(t) == Schedule.freq_start_for_round(round)
    end
  end

  test "the worked example: round 33068212 (20:00:00) reads from 19:54:00 and closes at 19:59:45" do
    %{rows: [[t, f]]} =
      Repo.query!(
        "SELECT wallop_freq_start(33068212), wallop_freq_fetch_deadline(wallop_freq_start(33068212))"
      )

    assert utc(t) == ~U[2026-10-14 19:54:00.000000Z]
    assert utc(f) == ~U[2026-10-14 19:59:45.000000Z]
  end

  test "the SQL constants equal the Elixir ones" do
    %{rows: [[tag, w, span, margin, gap, n, reason]]} =
      Repo.query!("""
      SELECT wallop_freq_tag(),
             EXTRACT(EPOCH FROM wallop_freq_fetch_window())::int,
             EXTRACT(EPOCH FROM wallop_freq_span())::int,
             EXTRACT(EPOCH FROM wallop_freq_margin())::int,
             EXTRACT(EPOCH FROM wallop_freq_lock_gap())::int,
             wallop_freq_stuck_run(),
             wallop_freq_fallback_reason()
      """)

    assert tag == Freq.tag()
    assert w == Schedule.fetch_window_seconds()
    assert span == Schedule.span_seconds()
    assert margin == Schedule.margin_seconds()
    assert gap == Schedule.lock_gap_seconds()
    assert n == FreqGrammar.stuck_run()
    assert reason == Freq.fallback_reason()
  end

  test "the SQL key sets equal the tag's, sorted bytewise" do
    %{rows: [[lock, exec]]} =
      Repo.query!("SELECT wallop_freq_lock_keys(), wallop_freq_exec_keys()")

    assert lock == Freq.lock_keys()
    assert exec == Freq.exec_keys()
    assert lock == Enum.sort(lock) and exec == Enum.sort(exec)
  end

  test "wallop_freq_lock_allowed is inclusive at T - 60 s, to the microsecond" do
    t = ~N[2026-10-14 19:54:00.000000]
    q = fn at -> Repo.query!("SELECT wallop_freq_lock_allowed($1, $2)", [at, t]).rows end
    assert q.(~N[2026-10-14 19:53:00.000000]) == [[true]]
    assert q.(~N[2026-10-14 19:53:00.000001]) == [[false]]
  end

  test "wallop_v6_fetch_deadline chooses F by tag, and NULL for an unknown tag" do
    t = ~U[2026-10-14 19:54:00.000000Z]
    wt = ~U[2026-10-14 19:00:00.000000Z]

    q = fn tag ->
      Repo.query!("SELECT wallop_v6_fetch_deadline($1, $2, $3)", [tag, naive(wt), naive(t)]).rows
    end

    assert q.(Freq.tag()) == [[naive(Schedule.fetch_deadline(t))]]

    assert q.(WallopCore.Protocol.landobs_entropy_composition()) == [
             [naive(WallopCore.Weather.Schedule.fetch_deadline(wt))]
           ]

    assert q.("drand-quicknet+elexon-freq-v2") == [[nil]]
    assert q.(nil) == [[nil]]
  end

  defp sql_valid?(value) do
    %{rows: [[ok]]} = Repo.query!("SELECT wallop_freq_valid_value($1)", [value])
    ok
  end

  property "SQL value validity matches the grammar, on malformed strings" do
    reading = member_of(~w(00000 46999 47000 49987 50000 52999 53000 4998 050000))

    check all(
            parts <- list_of(reading, min_length: 6, max_length: 10),
            sep <- member_of([";", ",", "; "]),
            max_runs: 300
          ) do
      value = Enum.join(parts, sep)
      assert sql_valid?(value) == FreqGrammar.valid_value?(value), value
    end
  end

  property "SQL value validity matches the grammar, on 8 in-bound readings (stuck runs)" do
    check all(parts <- list_of(member_of(~w(47000 49987 50000 52999)), length: 8), max_runs: 500) do
      value = Enum.join(parts, ";")
      assert sql_valid?(value) == FreqGrammar.valid_value?(value), value
    end
  end

  test "the stuck boundary, exactly, and NULL" do
    refute sql_valid?("50000;50000;50000;50000;50000;50000;50012;50013")
    assert sql_valid?("50000;50000;50000;50000;50000;50011;50012;50013")
    refute sql_valid?(nil)
  end

  test "N agrees everywhere: the CHECK's literal, wallop_freq_stuck_run() and FreqGrammar" do
    n = FreqGrammar.stuck_run()

    %{rows: [[sql_n, src]]} =
      Repo.query!(
        "SELECT wallop_freq_stuck_run(), prosrc FROM pg_proc WHERE proname = 'wallop_freq_valid_value'"
      )

    assert sql_n == n
    assert src =~ "IF run >= #{n} THEN"
    refute src =~ "wallop_freq_stuck_run"

    # Behaviour on both sides of N, built from n so a mismatch fails here.
    run_of = fn k ->
      List.duplicate("50000", k) ++ Enum.map(1..(8 - k), &Integer.to_string(50_000 + &1))
    end

    refute sql_valid?(Enum.join(run_of.(n), ";"))
    assert sql_valid?(Enum.join(run_of.(n - 1), ";"))
  end
end
