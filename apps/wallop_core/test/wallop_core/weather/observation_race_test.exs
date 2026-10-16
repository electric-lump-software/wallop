defmodule WallopCore.Weather.ObservationRaceTest do
  @moduledoc """
  The observation store racing itself and the draw's completion, in real
  transactions that really commit.

    * A completion that arrives while a store is uncommitted waits on the
      draw's row lock and then reads the store afresh: it can't fall back past
      a reading that commits first.
    * Two draws of one hour storing different values at once: the second
      waits for the first and is then refused, so the one-value rule holds
      under concurrency too.

  The Ecto sandbox wraps each test in one transaction, which can't show a
  race, so this runs outside it with `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`
  (as `V6LockReceiptRaceTest` does). Fixtures belong to one fresh operator and
  are deleted at the end with triggers off.
  """
  use ExUnit.Case, async: false

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Weather.{Observations, Stations}

  @blocked_ms 300
  @value "141;1025;85;2432"

  setup do
    {operator, key} = unboxed(fn -> create_v6_operator() end)
    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    %{key: key}
  end

  # v6 draws in pending_entropy sharing one stored weather_time five minutes
  # ago (the primary window), with a round published ten seconds ago.
  defp pending_draws(key, n) do
    unboxed(fn ->
      wt = DateTime.utc_now() |> DateTime.add(-5 * 60) |> DateTime.truncate(:second)
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))

      for _ <- 1..n do
        draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)

        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
          Ecto.UUID.dump!(draw.id)
        ])

        draw
      end
    end)
  end

  defp reading(draw, value), do: %{value: value, raw: "[]", observation_time: draw.weather_time}

  defp store(draw, value),
    do: fn -> Observations.store(draw.id, Stations.primary().id, reading(draw, value)) end

  defp fallback(draw) do
    fn ->
      Repo.query!(
        "UPDATE draws SET status = 'completed', executed_at = $2, weather_fallback_reason = $3 WHERE id = $1",
        [Ecto.UUID.dump!(draw.id), NaiveDateTime.utc_now(), LandObs.fallback_reason()]
      )
    end
  end

  test "a fallback completion during an uncommitted store waits, then reads the stored row", %{
    key: key
  } do
    [draw] = pending_draws(key, 1)

    t1 = in_transaction(store(draw, @value))
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
    assert stored_values(draw) == [@value]
  end

  test "a different value for the same hour, stored concurrently, waits and is refused", %{
    key: key
  } do
    [a, b, c] = pending_draws(key, 3)

    t1 = in_transaction(store(a, @value))
    assert_receive {:done_statement, ^t1}, 5_000

    t2 = in_transaction(store(b, "142;1025;85;2432"))
    refute_receive {:done_statement, ^t2}, @blocked_ms

    send(t1, :commit)
    assert_receive {:result, ^t1, :committed}, 5_000

    assert_receive {:result, ^t2, {:refused, message}}, 5_000
    assert message =~ "a different value is already stored for this station and hour"

    # Control: the same value, concurrently, waits and then is stored.
    t3 = in_transaction(store(c, @value))
    assert_receive {:done_statement, ^t3}, 5_000
    send(t3, :commit)
    assert_receive {:result, ^t3, :committed}, 5_000

    assert stored_values(a) == [@value]
    assert stored_values(b) == []
    assert stored_values(c) == [@value]
  end

  # Runs `statement` in a real transaction in a new process. Reports
  # {:done_statement, pid} when it returns, then waits for :commit. Reports
  # {:result, pid, :committed | {:refused, message}}.
  defp in_transaction(statement) do
    parent = self()

    spawn(fn ->
      me = self()

      result =
        try do
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL lock_timeout = '10s'")

              case statement.() do
                {:error, error} -> Repo.rollback({:refused, Exception.message(error)})
                _ -> :ok
              end

              send(parent, {:done_statement, me})

              receive do
                :commit -> :ok
              after
                10_000 -> Repo.rollback(:no_commit)
              end
            end)
          end)
        rescue
          e in Postgrex.Error -> {:error, {:refused, e.postgres.message}}
        end

      case result do
        {:ok, :ok} ->
          send(parent, {:result, me, :committed})

        {:error, {:refused, message}} ->
          send(parent, {:result, me, {:refused, message}})

        # A refusal inside Ash's create rolls back this whole transaction.
        {:error, %Ash.Changeset{errors: errors}} ->
          send(parent, {:result, me, {:refused, inspect(errors)}})

        other ->
          send(parent, {:result, me, other})
      end
    end)
  end

  defp status(draw) do
    unboxed(fn ->
      %{rows: [[s]]} =
        Repo.query!("SELECT status FROM draws WHERE id = $1", [Ecto.UUID.dump!(draw.id)])

      s
    end)
  end

  defp stored_values(draw) do
    unboxed(fn ->
      %{rows: rows} =
        Repo.query!("SELECT value FROM weather_observations WHERE draw_id = $1", [
          Ecto.UUID.dump!(draw.id)
        ])

      List.flatten(rows)
    end)
  end

  defp delete_operator!(operator_id) do
    id = Ecto.UUID.dump!(operator_id)
    draws = "SELECT id FROM draws WHERE operator_id = $1"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      for sql <- [
            "DELETE FROM weather_observations WHERE draw_id IN (#{draws})",
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
