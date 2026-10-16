defmodule WallopCore.Weather.V6LockReceiptRaceTest do
  @moduledoc """
  A v6 lock and a lock receipt racing in two real transactions, in both
  orders. The final state must never be a v6 draw with a non-v6 receipt.

  The Ecto sandbox wraps each test in one transaction, which can't show a
  race. So this test runs outside it with
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`: each transaction gets its own
  real connection and really commits. The fixtures it commits belong to one
  fresh operator and are deleted at the end, with triggers off (the
  immutability triggers forbid deleting receipts otherwise).
  """
  use ExUnit.Case, async: false

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Weather.{Schedule, Stations}

  @lock_sql """
  UPDATE draws SET status = 'awaiting_entropy', lock_schema_version = '6',
    entropy_composition = $2, drand_chain = $3, drand_round = $4, weather_time = $5,
    weather_station = $6, entry_hash = $7, entry_canonical = $8
  WHERE id = $1
  """

  # How long a blocked statement is given to show it is waiting.
  @blocked_ms 300

  setup do
    {operator, draw, s} =
      unboxed(fn ->
        operator = create_operator()
        key = create_api_key_for_operator(operator)
        draw = open_draw_with_entries(key)
        {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
        hashes = Protocol.entry_hash({draw.id, WallopCore.Entries.load_for_draw(draw.id)})
        {operator, draw, Map.put(s, :hashes, hashes)}
      end)

    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)

    %{draw: draw, s: s}
  end

  test "a non-v6 receipt inserted during an uncommitted v6 lock waits, then is refused", %{
    draw: draw,
    s: s
  } do
    t1 = in_transaction(fn -> lock!(draw, s) end)
    assert_receive {:done_statement, ^t1}, 5_000

    t2 = in_transaction(fn -> insert_schema5_receipt!(draw, s) end)
    refute_receive {:done_statement, ^t2}, @blocked_ms

    send(t1, :commit)
    assert_receive {:result, ^t1, :committed}, 5_000

    assert_receive {:result, ^t2, {:refused, message}}, 5_000
    assert message == "a v6 lock receipt must carry its draw's schema and entropy_composition"

    assert final_state(draw) == {"6", LandObs.tag(), []}
  end

  test "a v6 lock during an uncommitted non-v6 receipt insert waits, then is refused", %{
    draw: draw,
    s: s
  } do
    t1 = in_transaction(fn -> insert_schema5_receipt!(draw, s) end)
    assert_receive {:done_statement, ^t1}, 5_000

    t2 = in_transaction(fn -> lock!(draw, s) end)
    refute_receive {:done_statement, ^t2}, @blocked_ms

    send(t1, :commit)
    assert_receive {:result, ^t1, :committed}, 5_000

    assert_receive {:result, ^t2, {:refused, message}}, 5_000
    assert message == "a v6 lock receipt must carry its draw's schema and entropy_composition"

    assert final_state(draw) == {nil, nil, ["5"]}
  end

  # Runs `statement` in a real transaction in a new process. Reports
  # {:done_statement, pid} when the statement returns, then waits for
  # :commit. Reports {:result, pid, :committed | {:refused, message}}.
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
        other -> send(parent, {:result, me, other})
      end
    end)
  end

  defp lock!(draw, s) do
    {hash, canonical} = s.hashes

    Repo.query!(@lock_sql, [
      Ecto.UUID.dump!(draw.id),
      LandObs.tag(),
      Quicknet.chain_hash(),
      s.round,
      DateTime.to_naive(s.weather_time),
      Stations.primary().id,
      hash,
      canonical
    ])
  end

  # A receipt as a forecast lock would write it: not schema 6, so a draw
  # without a lock schema accepts it.
  defp insert_schema5_receipt!(draw, s) do
    {hash, _} = s.hashes
    locked_at = DateTime.utc_now()

    payload =
      Jason.encode!(%{
        "schema_version" => "5",
        "draw_id" => draw.id,
        "locked_at" => WallopCore.Time.to_rfc3339_usec(locked_at)
      })

    Repo.query!(
      """
      INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
        entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $5, $6, 'k', $7, $8, $6)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(draw.operator_id),
        Ecto.UUID.dump!(draw.id),
        draw.operator_sequence,
        hash,
        DateTime.to_naive(locked_at),
        payload,
        :binary.copy(<<0>>, 64)
      ]
    )
  end

  # {lock_schema_version, entropy_composition, [receipt schema_version]}
  defp final_state(draw) do
    unboxed(fn ->
      %{rows: [[schema, tag]]} =
        Repo.query!(
          "SELECT lock_schema_version, entropy_composition FROM draws WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )

      %{rows: receipts} =
        Repo.query!(
          "SELECT convert_from(payload_jcs, 'UTF8')::jsonb->>'schema_version' FROM operator_receipts WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )

      {schema, tag, List.flatten(receipts)}
    end)
  end

  defp delete_operator!(operator_id) do
    id = Ecto.UUID.dump!(operator_id)
    draws = "SELECT id FROM draws WHERE operator_id = $1"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      for sql <- [
            "DELETE FROM oban_jobs WHERE args->>'draw_id' IN (SELECT id::text FROM draws WHERE operator_id = $1)",
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
