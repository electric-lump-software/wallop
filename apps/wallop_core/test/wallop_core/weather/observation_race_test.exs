defmodule WallopCore.Weather.ObservationRaceTest do
  @moduledoc """
  The observation store racing itself and the draws' completion, in real
  transactions that really commit.

    * A completion that arrives while the hour's store is uncommitted waits
      on the draw's row lock and then reads the store afresh: it can't fall
      back past a reading that commits first.
    * A primary insert still uncommitted at the backup cutover, and a backup
      insert for the same hour after it: the backup waits on the hour's
      unique index and is then refused.
    * Two different primary values for one hour at once: the first wins and
      the second waits, then is refused.

  Each race has a concurrent control: when the first transaction rolls back
  instead, the waiting one is stored.

  The stores here are raw INSERTs in transactions this test controls:
  `Observations.store/2` refuses to run inside a caller's transaction, and
  the point is to hold one open. The Ecto sandbox wraps each test in one
  transaction, which can't show a race, so this runs outside it with
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` (as `V6LockReceiptRaceTest`
  does). Fixtures belong to one fresh operator and are deleted at the end
  with triggers off.
  """
  use ExUnit.Case, async: false

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Weather.{Schedule, Stations}

  @blocked_ms 300
  @value "141;1025;85;2432"
  @w Schedule.fetch_window_seconds()
  @unique "duplicate key value violates unique constraint \"weather_observations_one_per_hour_index\""

  setup do
    {operator, key} = unboxed(fn -> create_v6_operator() end)
    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    %{key: key}
  end

  # A v6 draw in pending_entropy whose stored weather_time is `wt_offset`
  # seconds from now, with a round published ten seconds ago.
  defp pending_draw(key, wt_offset) do
    unboxed(fn ->
      wt = DateTime.utc_now() |> DateTime.add(wt_offset) |> DateTime.truncate(:second)
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
      draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)

      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
        Ecto.UUID.dump!(draw.id)
      ])

      draw
    end)
  end

  defp insert(draw, station, value \\ @value) do
    fn ->
      Repo.query!(
        """
        INSERT INTO weather_observations (id, station, observation_time, value, raw)
        VALUES (gen_random_uuid(), $1, $2, $3, '[]')
        """,
        [station, DateTime.to_naive(draw.weather_time), value]
      )
    end
  end

  defp fallback(draw) do
    fn ->
      Repo.query!(
        "UPDATE draws SET status = 'completed', executed_at = $2, weather_fallback_reason = $3 WHERE id = $1",
        [Ecto.UUID.dump!(draw.id), NaiveDateTime.utc_now(), LandObs.fallback_reason()]
      )
    end
  end

  describe "a completion during an uncommitted store" do
    test "waits, then reads the stored row", %{key: key} do
      draw = pending_draw(key, -5 * 60)

      t1 = in_transaction(insert(draw, Stations.primary().id))
      assert_receive {:done_statement, ^t1}, 5_000

      t2 = in_transaction(fallback(draw))
      refute_receive {:done_statement, ^t2}, @blocked_ms

      send(t1, :commit)
      assert_receive {:result, ^t1, :committed}, 5_000

      # Had the guard read the store before the lock, it would have found
      # nothing and refused for the deadline instead.
      assert_receive {:result, ^t2,
                      {:refused, "v6 draw must complete with its stored observation"}},
                     5_000

      assert status(draw) == "pending_entropy"
      assert stored(draw) == [{Stations.primary().id, @value}]
    end
  end

  describe "a backup insert during an uncommitted primary insert, across the cutover" do
    @tag :slow
    test "waits, then is refused once the primary commits", %{key: key} do
      {draw, t1, t2} = across_cutover(key)

      send(t1, :commit)
      assert_receive {:result, ^t1, :committed}, 5_000
      assert_receive {:result, ^t2, {:refused, @unique}}, 5_000

      assert stored(draw) == [{Stations.primary().id, @value}]
    end

    @tag :slow
    test "control: is stored if the primary rolls back", %{key: key} do
      {draw, t1, t2} = across_cutover(key)

      send(t1, :rollback)
      assert_receive {:result, ^t1, :rolled_back}, 5_000
      assert_receive {:done_statement, ^t2}, 5_000
      send(t2, :commit)
      assert_receive {:result, ^t2, :committed}, 5_000

      assert stored(draw) == [{Stations.backup().id, "90;1025;85;2432"}]
    end
  end

  describe "two different primary values for one hour at once" do
    test "the first wins; the second waits, then is refused", %{key: key} do
      {draw, t1, t2} = two_primaries(key)

      send(t1, :commit)
      assert_receive {:result, ^t1, :committed}, 5_000
      assert_receive {:result, ^t2, {:refused, @unique}}, 5_000

      assert stored(draw) == [{Stations.primary().id, @value}]
    end

    test "control: the second is stored if the first rolls back", %{key: key} do
      {draw, t1, t2} = two_primaries(key)

      send(t1, :rollback)
      assert_receive {:result, ^t1, :rolled_back}, 5_000
      assert_receive {:done_statement, ^t2}, 5_000
      send(t2, :commit)
      assert_receive {:result, ^t2, :committed}, 5_000

      assert stored(draw) == [{Stations.primary().id, "142;1025;85;2432"}]
    end
  end

  # The cutover is a few seconds ahead: the primary's statement runs inside
  # the primary window; the backup's after the cutover, inside its own.
  defp across_cutover(key) do
    draw = pending_draw(key, -(@w - 10 * 60) + 3)
    cutover = Schedule.backup_cutover(draw.weather_time)

    t1 = in_transaction(insert(draw, Stations.primary().id))
    assert_receive {:done_statement, ^t1}, 5_000
    assert DateTime.compare(db_now(), cutover) == :lt

    wait_until_db_clock_after(cutover)
    t2 = in_transaction(insert(draw, Stations.backup().id, "90;1025;85;2432"))
    refute_receive {:done_statement, ^t2}, @blocked_ms

    {draw, t1, t2}
  end

  defp two_primaries(key) do
    draw = pending_draw(key, -5 * 60)

    t1 = in_transaction(insert(draw, Stations.primary().id))
    assert_receive {:done_statement, ^t1}, 5_000

    t2 = in_transaction(insert(draw, Stations.primary().id, "142;1025;85;2432"))
    refute_receive {:done_statement, ^t2}, @blocked_ms

    {draw, t1, t2}
  end

  # Runs `statement` in a real transaction in a new process. Reports
  # {:done_statement, pid} when it returns, then waits for :commit or
  # :rollback. Reports {:result, pid, :committed | :rolled_back |
  # {:refused, message}}.
  defp in_transaction(statement) do
    parent = self()

    spawn(fn ->
      me = self()

      result =
        try do
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL lock_timeout = '10s'")
              statement.()
              send(parent, {:done_statement, me})

              receive do
                :commit -> :ok
                :rollback -> Repo.rollback(:rolled_back)
              after
                10_000 -> Repo.rollback(:no_commit)
              end
            end)
          end)
        rescue
          e in Postgrex.Error -> {:refused, e.postgres.message}
        end

      case result do
        {:ok, :ok} -> send(parent, {:result, me, :committed})
        {:error, :rolled_back} -> send(parent, {:result, me, :rolled_back})
        other -> send(parent, {:result, me, other})
      end
    end)
  end

  defp db_now do
    unboxed(fn ->
      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")
      DateTime.from_naive!(now, "Etc/UTC")
    end)
  end

  defp wait_until_db_clock_after(t) do
    if DateTime.compare(db_now(), t) == :gt do
      :ok
    else
      Process.sleep(200)
      wait_until_db_clock_after(t)
    end
  end

  defp status(draw) do
    unboxed(fn ->
      %{rows: [[s]]} =
        Repo.query!("SELECT status FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)])

      s
    end)
  end

  defp stored(draw) do
    unboxed(fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT station, value FROM weather_observations WHERE observation_time = $1",
          [DateTime.to_naive(draw.weather_time)]
        )

      Enum.map(rows, &List.to_tuple/1)
    end)
  end

  defp delete_operator!(operator_id) do
    id = Ecto.UUID.dump!(operator_id)
    draws = "SELECT id FROM draws WHERE operator_id = $1"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      for sql <- [
            "DELETE FROM weather_observations WHERE observation_time IN (SELECT weather_time FROM draws WHERE operator_id = $1)",
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

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
