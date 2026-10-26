defmodule WallopCore.Frequency.WindowStoreTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.{Schedule, Windows}
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Resources.FrequencyWindow

  @value "50012;50018;50012;49983;49980;49953;49912;49883"

  defp freq_draw(t) do
    {_op, key} = create_freq_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))
    put_freq_awaiting!(open_draw_with_entries(key), t, round)
  end

  # now - T is in [165, 180): inside [T + 105 s, F].
  defp inside, do: aligned_freq_start(-(Schedule.span_seconds() + 60))

  # Straight to the action, past Windows.store/3's raw check, so the
  # triggers and CHECKs are what is tested.
  defp db_store(t, value),
    do:
      FrequencyWindow
      |> Ash.Changeset.for_create(:store, %{freq_start: t, value: value, raw: "{}"})
      |> Ash.create(authorize?: false)

  defp message({:error, error}), do: Exception.message(error)

  # The name of the CHECK a refused store broke.
  defp constraint({:error, %Ash.Error.Invalid{errors: [%{private_vars: vars}]}}),
    do: vars[:constraint]

  test "SQL wallop_freq_store_allowed: exact boundaries [T + 105 s, F], in a non-UTC session" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")
    t = ~N[2026-10-14 19:54:00.000000]
    from = Schedule.span_seconds() * 1_000_000
    f = (Schedule.span_seconds() + Schedule.fetch_window_seconds()) * 1_000_000

    for {offset, expected} <- [{from - 1, false}, {from, true}, {f, true}, {f + 1, false}] do
      %{rows: [[ok]]} =
        Repo.query!("SELECT wallop_freq_store_allowed($1, $2)", [
          t,
          NaiveDateTime.add(t, offset, :microsecond)
        ])

      assert ok == expected, "at #{offset} us"
    end
  end

  test "a valid window is stored once for its T, stamped by the database clock" do
    t = inside()
    freq_draw(t)
    freq_draw(t)
    assert {:ok, w} = Windows.store(t, @value, elexon_body(t, @value))
    assert w.stored_at
    assert Windows.for_start(t).value == @value

    assert message(Windows.store(t, @value, elexon_body(t, @value))) =~
             "a window is already stored for this start"
  end

  test "store/3 refuses a value the raw response doesn't give" do
    t = inside()
    freq_draw(t)
    other = "50012;50018;50012;49983;49980;49953;49912;49884"
    assert {:error, :raw_does_not_give_value} = Windows.store(t, @value, elexon_body(t, other))
    assert {:error, :raw_does_not_give_value} = Windows.store(t, @value, "{}")
    assert Windows.for_start(t) == nil
  end

  test "outside the window nothing is stored" do
    early = aligned_freq_start(-60)
    freq_draw(early)
    assert message(db_store(early, @value)) =~ "frequency window outside its fetch window"

    late = aligned_freq_start(-(Schedule.span_seconds() + Schedule.fetch_window_seconds() + 60))
    freq_draw(late)
    assert message(db_store(late, @value)) =~ "frequency window outside its fetch window"
  end

  test "the CHECKs refuse a value outside the grammar, the bounds or the stuck rule, and an off-grid T" do
    t = inside()
    freq_draw(t)

    for bad <- [
          "50018;50012;49983",
          "00000;50012;49983;49980;49953;49912;49883;49887",
          "53000;50012;49983;49980;49953;49912;49883;49887",
          "50000;50000;50000;50000;50000;50000;50012;50013"
        ] do
      assert constraint(db_store(t, bad)) == "frequency_windows_value_grammar", bad
    end

    off_grid = DateTime.add(t, 1)
    freq_draw(off_grid)
    assert constraint(db_store(off_grid, @value)) == "frequency_windows_on_grid"
  end

  test "no waiting draw for the window: refused" do
    assert message(db_store(inside(), @value)) =~ "no draw is waiting for this window"
  end

  test "a window is stored when only a weather-tag draw waits on its T" do
    {_op, key} = create_v6_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 60))

    d =
      put_v6_awaiting!(
        open_draw_with_entries(key),
        WallopCore.Weather.Schedule.weather_time_for_round(round),
        round
      )

    assert {:ok, _} = Windows.store(d.freq_start, @value, elexon_body(d.freq_start, @value))
  end

  test "it refuses to run inside a caller's transaction, and sets short timeouts" do
    t = inside()
    freq_draw(t)

    assert Repo.transaction(fn -> Windows.store(t, @value, elexon_body(t, @value)) end) ==
             {:ok, {:error, :nested_transaction}}

    assert {:ok, _} = Windows.store(t, @value, elexon_body(t, @value))
    assert Repo.query!("SHOW statement_timeout").rows == [["5s"]]
    assert Repo.query!("SHOW idle_in_transaction_session_timeout").rows == [["5s"]]
  end

  test "rows are write-once: no UPDATE, DELETE or TRUNCATE" do
    t = inside()
    freq_draw(t)
    {:ok, _} = Windows.store(t, @value, elexon_body(t, @value))
    naive = DateTime.to_naive(t)

    assert db_refused?("UPDATE frequency_windows SET value = $2 WHERE freq_start = $1", [
             naive,
             "50012;50018;50012;49983;49980;49953;49912;49884"
           ])

    assert db_refused?("DELETE FROM frequency_windows WHERE freq_start = $1", [naive])
    assert db_refused?("TRUNCATE frequency_windows", [])
  end

  test "the window does not depend on the session time zone" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")
    t = inside()
    freq_draw(t)
    assert {:ok, _} = Windows.store(t, @value, elexon_body(t, @value))
  end

  test "pending_draw_ids lists T's waiting draws until T has its window; for_draw reads it" do
    t = inside()
    a = freq_draw(t)
    b = freq_draw(t)
    assert Enum.sort(Windows.pending_draw_ids(t)) == Enum.sort([a.id, b.id])
    {:ok, _} = Windows.store(t, @value, elexon_body(t, @value))
    assert Windows.pending_draw_ids(t) == []
    assert Windows.for_draw(a).value == @value
    assert Windows.for_draw(a.id).value == @value
  end

  # Each case gets its own T inside its window (now - T in [135, 330)), so
  # one stored window never decides another case.
  defp case_start(i), do: aligned_freq_start(-(135 + 15 * i))

  defp set_status!(draw, status) do
    Repo.query!("SET session_replication_role = replica")

    try do
      Repo.query!("UPDATE draws SET status = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        Atom.to_string(status)
      ])
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  test "pending_draw_ids waits for exactly the draws the store's insert trigger waits for" do
    assert Windows.waiting_tags() == [Freq.tag(), LandObs.tag()]

    {_op, v6_key} = create_v6_operator()
    {_op, freq_key} = create_freq_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))

    cases =
      for tag <- [Freq.tag(), LandObs.tag()],
          status <- [:awaiting_entropy, :pending_entropy, :completed, :failed, :expired],
          do: {tag, status}

    for {{tag, status}, i} <- Enum.with_index(cases) do
      t = case_start(i)

      draw =
        if tag == Freq.tag(),
          do: put_freq_awaiting!(open_draw_with_entries(freq_key), t, round),
          else:
            put_v6_awaiting!(open_draw_with_entries(v6_key), ~U[2026-10-14 19:00:00Z], round,
              freq_start: t
            )

      if status != :awaiting_entropy, do: set_status!(draw, status)

      waits? = status in [:awaiting_entropy, :pending_entropy]
      label = "#{tag} #{status}"

      assert Windows.pending_draw_ids(t) == if(waits?, do: [draw.id], else: []), label

      stored = Windows.store(t, @value, elexon_body(t, @value))
      assert match?({:ok, _}, stored) == waits?, label
      unless waits?, do: assert(message(stored) =~ "no draw is waiting for this window", label)
    end
  end

  test "actors can't read or store windows" do
    {_op, key} = create_freq_operator()
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(FrequencyWindow, actor: key)
  end
end
