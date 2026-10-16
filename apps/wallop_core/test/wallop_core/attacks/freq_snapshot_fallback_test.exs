defmodule WallopCore.Attacks.FreqSnapshotFallbackTest do
  @moduledoc """
  The draws guard and the execution receipt guard decide "stored window or
  fallback" with a plain `SELECT ... FROM frequency_windows` (Land Obs:
  `weather_observations`). Under READ COMMITTED that read sees every
  committed row. Under REPEATABLE READ (or SERIALIZABLE) it sees the
  transaction's snapshot, which may predate the store.

  Attack (raw SQL, no superuser: in the threat model):

    1. before T's window commits, open a REPEATABLE READ transaction and
       take its snapshot (any SELECT);
    2. the honest worker stores T's window and commits before F;
    3. wait past F + M (drand's round R is public from pub(R) >= F + M,
       so the attacker now knows both candidate seeds);
    4. in the old transaction, complete the draw with the fallback.

  The guard read the old snapshot, found no window, saw the clock past
  F + M, and let the fallback through, so "the fallback only with nothing
  stored" and "every draw of T agrees" no longer held. Same shape for Land
  Obs.

  Fix: `guard_v6_draw` (after the forecast early return),
  `guard_v6_execution_receipt` (after the forecast early return), and both
  stores' insert guards refuse unless the transaction is READ COMMITTED,
  so every read of stored state is a fresh snapshot.

  Everything here commits or rolls back outside the sandbox and removes
  what it created.
  """
  use ExUnit.Case, async: false

  import WallopCore.TestHelpers
  import WallopCore.UnboxedHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Protocol.Tags.Freq
  alias WallopCore.Repo
  alias WallopCore.Weather.Schedule, as: WeatherSchedule
  alias WallopCore.Weather.Stations

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
  @isolation "a v6 write must run under READ COMMITTED isolation"
  @levels ["REPEATABLE READ", "SERIALIZABLE"]

  setup do
    own = fn {operator, _key} = pair ->
      on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
      pair
    end

    %{own: own}
  end

  # Runs `statement` in a real transaction at `level`, then rolls back.
  defp at_level(level, statement) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL #{level}")

        outcome =
          try do
            statement.()
            :passed
          rescue
            e in Postgrex.Error -> {:refused, e.postgres.message}
          end

        Repo.rollback(outcome)
      end)
    end)
    |> then(fn {:error, outcome} -> outcome end)
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp receipt_insert(draw) do
    Repo.query!(
      "INSERT INTO execution_receipts (draw_id, operator_id, sequence, lock_receipt_hash, " <>
        "payload_jcs, signature, signing_key_id) VALUES ($1, $2, 1, 'x', 'x', 'x', 'x')",
      [dump(draw.id), dump(draw.operator_id)]
    )
  end

  # A T on the 15 s grid whose F is 12 to 27 s away, so the store is open now
  # and stays open through the fixture set-up.
  defp t_closing_soon do
    now = DateTime.to_unix(DateTime.utc_now())
    lead = Schedule.span_seconds() + Schedule.fetch_window_seconds() - 12
    t = now - lead + Integer.mod(-(now - lead), 15)
    DateTime.from_unix!(t * 1_000_000, :microsecond)
  end

  defp fallback_completion(draw_id) do
    Repo.query!(
      "UPDATE draws SET status = 'completed', executed_at = $2, " <>
        "freq_fallback_reason = $3 WHERE id = $1",
      [dump(draw_id), NaiveDateTime.utc_now(), Freq.fallback_reason()]
    )

    :completed_with_fallback
  rescue
    e in Postgrex.Error -> {:refused, e.postgres.message}
  end

  defp stale(parent, me, draw_id) do
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
    Repo.query!("SELECT count(*) FROM frequency_windows")
    send(parent, {:snapshot, me})

    receive do
      :go -> :ok
    after
      60_000 -> Repo.rollback(:no_go)
    end

    Repo.rollback(fallback_completion(draw_id))
  end

  # Holds a REPEATABLE READ transaction: takes its snapshot, waits for :go,
  # runs the fallback completion, reports, then rolls back.
  defp stale_snapshot_completion(draw_id) do
    parent = self()

    spawn_link(fn ->
      me = self()
      send(parent, {:result, me, unboxed(fn -> stale_transaction(parent, me, draw_id) end)})
    end)
  end

  defp stale_transaction(parent, me, draw_id),
    do: Repo.transaction(fn -> stale(parent, me, draw_id) end, timeout: 90_000)

  @tag :slow
  test "a stale snapshot can't fall back past a stored window", %{own: own} do
    {_operator, key} = own.(unboxed(fn -> create_freq_operator() end))
    t = t_closing_soon()

    d =
      unboxed(fn ->
        round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
        d = put_freq_awaiting!(open_draw_with_entries(key), t, round)

        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)])

        d
      end)

    pid = stale_snapshot_completion(d.id)
    assert_receive {:snapshot, ^pid}, 5_000

    # The honest store, committed in time.
    unboxed(fn ->
      Repo.query!(
        "INSERT INTO frequency_windows (id, freq_start, value, raw) " <>
          "VALUES (gen_random_uuid(), $1, $2, '{}')",
        [DateTime.to_naive(t), @value]
      )
    end)

    assert unboxed(fn ->
             Repo.query!("SELECT count(*) FROM frequency_windows WHERE freq_start = $1", [
               DateTime.to_naive(t)
             ]).rows
           end) == [[1]]

    # Past F + M: drand's round is public from here.
    unboxed(fn ->
      wait_until_db_clock_after(
        DateTime.add(Schedule.fetch_deadline(t), Schedule.margin_seconds())
      )
    end)

    send(pid, :go)
    assert_receive {:result, ^pid, {:error, outcome}}, 10_000
    assert outcome == {:refused, @isolation}
  end

  describe "grid frequency, under each isolation level above READ COMMITTED" do
    setup %{own: own} do
      {_operator, key} = own.(unboxed(fn -> create_freq_operator() end))
      t = aligned_freq_start(-(Schedule.span_seconds() + 30))
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))
      %{draw: unboxed(fn -> put_freq_awaiting!(open_draw_with_entries(key), t, round) end), t: t}
    end

    test "a draw update is refused", %{draw: d} do
      for level <- @levels do
        assert at_level(level, fn ->
                 Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
                   dump(d.id)
                 ])
               end) == {:refused, @isolation},
               level
      end

      # Control: the same update under READ COMMITTED passes the guard.
      assert at_level("READ COMMITTED", fn ->
               Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
                 dump(d.id)
               ])
             end) == :passed
    end

    test "a window store is refused", %{t: t} do
      insert = fn ->
        Repo.query!(
          "INSERT INTO frequency_windows (id, freq_start, value, raw) " <>
            "VALUES (gen_random_uuid(), $1, $2, '{}')",
          [DateTime.to_naive(t), @value]
        )
      end

      for level <- @levels, do: assert(at_level(level, insert) == {:refused, @isolation}, level)
      # Control: the store's own rules decide under READ COMMITTED.
      assert at_level("READ COMMITTED", insert) == :passed
    end

    test "an execution receipt is refused", %{draw: d} do
      for level <- @levels do
        assert at_level(level, fn -> receipt_insert(d) end) == {:refused, @isolation}, level
      end

      assert {:refused, other} = at_level("READ COMMITTED", fn -> receipt_insert(d) end)
      refute other == @isolation
    end
  end

  describe "Land Obs, under each isolation level above READ COMMITTED" do
    setup %{own: own} do
      {_operator, key} = own.(unboxed(fn -> create_v6_operator() end))
      {:ok, s} = WeatherSchedule.schedule(WeatherSchedule.default_draw_at(DateTime.utc_now()))
      # Five minutes ago: "now" is inside the primary's store window.
      wt = DateTime.utc_now() |> DateTime.add(-5 * 60) |> DateTime.truncate(:second)
      %{draw: unboxed(fn -> put_v6_awaiting!(open_draw_with_entries(key), wt, s.round) end)}
    end

    test "a draw update is refused", %{draw: d} do
      update = fn ->
        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)])
      end

      for level <- @levels, do: assert(at_level(level, update) == {:refused, @isolation}, level)
      assert at_level("READ COMMITTED", update) == :passed
    end

    test "an observation store is refused", %{draw: d} do
      insert = fn ->
        Repo.query!(
          "INSERT INTO weather_observations (id, station, observation_time, value, raw) " <>
            "VALUES (gen_random_uuid(), $1, $2, '141;1025;85;2432', '[]')",
          [Stations.primary().id, DateTime.to_naive(d.weather_time)]
        )
      end

      for level <- @levels, do: assert(at_level(level, insert) == {:refused, @isolation}, level)
      assert at_level("READ COMMITTED", insert) == :passed
    end

    test "an execution receipt is refused", %{draw: d} do
      for level <- @levels do
        assert at_level(level, fn -> receipt_insert(d) end) == {:refused, @isolation}, level
      end

      assert {:refused, other} = at_level("READ COMMITTED", fn -> receipt_insert(d) end)
      refute other == @isolation
    end
  end

  describe "forecast draws are untouched" do
    test "an update and a receipt insert meet no isolation rule", %{own: own} do
      operator = unboxed(fn -> create_operator() end)
      own.({operator, nil})

      d =
        unboxed(fn ->
          open_draw_with_entries(create_api_key_for_operator(operator))
        end)

      for level <- @levels do
        assert at_level(level, fn ->
                 Repo.query!("UPDATE draws SET name = 'renamed' WHERE id = $1", [dump(d.id)])
               end) == :passed,
               level

        # The v6 guard returns early for a forecast draw; whatever else
        # refuses this placeholder receipt, it isn't the isolation rule.
        case at_level(level, fn -> receipt_insert(d) end) do
          :passed -> :ok
          {:refused, message} -> refute message == @isolation, level
        end
      end
    end
  end
end
