defmodule WallopCore.Attacks.ExecReceiptPairLockTest do
  @moduledoc """
  The execution receipt guard once read the draw's (lock_schema_version,
  entropy_composition) pair without a lock, and returned at once when it
  was NULL (a forecast draw). Two ways round the v6 rules followed:

    * REPEATABLE READ: a snapshot taken while the draw was still open reads
      the pair as NULL after the draw has locked, so a junk receipt is
      accepted. The unique index on draw_id then blocks the real receipt,
      and failing the draw is refused after F: it stalls for good.
    * READ COMMITTED: a receipt inserted while the draw is open, its
      transaction held open, is invisible to the lock's check for a stored
      execution receipt, so the lock goes through and the junk receipt
      commits after it.

  Fix: the guard reads the draw row FOR SHARE on every path. A later lock
  waits for the receipt's transaction and then sees the receipt; under
  REPEATABLE READ a draw changed since the snapshot is a serialization
  failure.

  Real commits outside the sandbox; each test removes its operator.
  """
  use ExUnit.Case, async: false

  import WallopCore.TestHelpers
  import WallopCore.UnboxedHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Protocol.Tags.Freq
  alias WallopCore.Repo

  @moduletag :slow

  setup do
    {operator, key} = unboxed(fn -> create_freq_operator() end)
    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    %{key: key}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp junk_receipt!(draw) do
    Repo.query!(
      "INSERT INTO execution_receipts (draw_id, operator_id, sequence, lock_receipt_hash, " <>
        "payload_jcs, signature, signing_key_id) VALUES ($1, $2, 1, 'x', 'x', 'x', 'x')",
      [dump(draw.id), dump(draw.operator_id)]
    )
  end

  defp receipts(draw) do
    unboxed(fn ->
      Repo.query!("SELECT count(*) FROM execution_receipts WHERE draw_id = $1", [dump(draw.id)]).rows
    end)
  end

  # The lock as raw SQL, with every trigger on: open to awaiting_entropy
  # under the frequency tag, an hour ahead, so only the receipt rule can
  # refuse it.
  defp raw_lock!(draw) do
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))

    Repo.query!(
      "UPDATE draws SET status = 'awaiting_entropy', lock_schema_version = '6', " <>
        "entropy_composition = $2, drand_chain = $3, drand_round = $4, freq_start = $5 " <>
        "WHERE id = $1",
      [
        dump(draw.id),
        Freq.tag(),
        Quicknet.chain_hash(),
        round,
        DateTime.to_naive(Schedule.freq_start_for_round(round))
      ]
    )
  end

  test "REPEATABLE READ: a snapshot from before the lock can't slip in a junk receipt", %{
    key: key
  } do
    draw = unboxed(fn -> open_draw_with_entries(key) end)
    parent = self()

    stale =
      spawn_link(fn ->
        me = self()

        result =
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
              Repo.query!("SELECT status FROM draws WHERE id = $1", [dump(draw.id)])
              send(parent, {:snapshot, me})
              receive do: (:go -> :ok)

              outcome =
                try do
                  junk_receipt!(draw)
                  :accepted
                rescue
                  e in Postgrex.Error -> {:refused, e.postgres.code}
                end

              # Keep whatever happened, so an accepted receipt really commits.
              if outcome == :accepted, do: outcome, else: Repo.rollback(outcome)
            end)
          end)

        send(parent, {:result, me, result})
      end)

    assert_receive {:snapshot, ^stale}, 5_000

    # The draw locks (fixture: triggers off) and commits after the snapshot.
    unboxed(fn -> put_freq_awaiting!(draw, Schedule.freq_start_for_round(1), 1) end)

    send(stale, :go)
    assert_receive {:result, ^stale, result}, 10_000
    assert {:error, {:refused, _code}} = result
    assert receipts(draw) == [[0]]
  end

  test "READ COMMITTED: a receipt held open while the draw is open makes the lock wait, then refuses it",
       %{key: key} do
    draw = unboxed(fn -> open_draw_with_entries(key) end)

    receipt = in_transaction(fn -> junk_receipt!(draw) end)
    assert_receive {:done_statement, ^receipt}, 5_000

    lock = in_transaction(fn -> raw_lock!(draw) end)
    # The lock waits on the receipt's row lock on the draw.
    refute_receive {:done_statement, ^lock}, 1_500

    send(receipt, :commit)
    assert_receive {:result, ^receipt, :committed}, 5_000

    assert_receive {:result, ^lock, {:refused, message}}, 10_000
    assert message == "a v6 draw can't lock with an execution receipt already stored"

    assert unboxed(fn ->
             Repo.query!("SELECT status FROM draws WHERE id = $1", [dump(draw.id)]).rows
           end) ==
             [["open"]]
  end

  test "control: the same raw lock with no receipt goes through", %{key: key} do
    draw = unboxed(fn -> open_draw_with_entries(key) end)
    lock = in_transaction(fn -> raw_lock!(draw) end)
    assert_receive {:done_statement, ^lock}, 5_000
    send(lock, :rollback)
    assert_receive {:result, ^lock, :rolled_back}, 5_000
  end
end
