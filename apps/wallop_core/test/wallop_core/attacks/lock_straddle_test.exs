defmodule WallopCore.Attacks.LockStraddleTest do
  @moduledoc """
  A v6 lock must not commit after its latest lock time.

  `statement_timestamp()` is when the UPDATE statement started, not when
  the row was changed and not when the transaction commits. A lock UPDATE
  that waits on a row lock, or a lock transaction left open, could
  otherwise land after `wt - 46m`, once its holder has seen the weather,
  and still be kept or dropped at will. So the draws guard reads the
  deadline on `clock_timestamp()` (after any row-lock wait), and a
  DEFERRABLE INITIALLY DEFERRED constraint trigger (`draws_v6_lock_commit`)
  reads it again at COMMIT.

  The deadline is always hh:14:00 UTC (the observation hour minus 46
  minutes), so a test can't place it a few seconds ahead the way the
  observation tests place F; a late commit can't be shown on demand. These
  tests pin that both checks exist and read the clock at the right moment,
  and show the commit-time check passing an in-time lock; a lock with no
  lock schema is refused before it gets there.
  """
  use WallopCore.InvariantCase, async: false

  alias WallopCore.Weather.Schedule

  @lock_call "wallop_landobs_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.weather_time)"

  test "a commit-time trigger re-checks the v6 lock deadline on the commit clock" do
    %{rows: rows} =
      Repo.query!("""
      SELECT p.prosrc, pg_get_triggerdef(t.oid) FROM pg_trigger t
      JOIN pg_proc p ON p.oid = t.tgfoid
      WHERE t.tgrelid = 'draws'::regclass AND t.tgname = 'draws_v6_lock_commit'
        AND t.tgdeferrable AND t.tginitdeferred AND t.tgenabled = 'O'
      """)

    assert [[src, def]] = rows
    assert src =~ @lock_call
    assert src =~ "v6 lock is too late for this draw time"
    assert def =~ "AFTER UPDATE ON public.draws"
    assert def =~ "(old.status = 'open'::text)"
  end

  test "the v6 lock check in the draws guard reads the clock after any row-lock wait" do
    %{rows: [[src]]} = Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'guard_v6_draw'")

    assert src =~ @lock_call
    refute src =~ "wallop_landobs_lock_allowed(now_utc"
  end

  test "an in-time lock through the lock action passes the commit-time check" do
    ensure_infrastructure_key()
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)

    {:ok, s} =
      Schedule.schedule(Schedule.default_draw_at(DateTime.add(DateTime.utc_now(), 3 * 3600)))

    assert check_now(fn ->
             {:ok, _} =
               draw
               |> Ash.Changeset.for_update(:lock, %{draw_at: s.draw_at}, actor: key)
               |> Ash.Changeset.set_context(%{warn_on_transaction_hooks?: false})
               |> Ash.update()
           end) == nil
  end

  test "a raw lock with no lock schema never reaches the commit-time check" do
    key = create_api_key()
    draw = open_draw_with_entries(key)

    assert check_now(fn ->
             Repo.query!("UPDATE draws SET status = 'awaiting_entropy' WHERE id = $1", [
               Ecto.UUID.dump!(draw.id)
             ])
           end) == "a draw leaves open only by locking under lock schema 6, or by expiring"
  end

  defp check_now(fun) do
    {:error, :accepted} =
      Repo.transaction(fn ->
        fun.()
        Repo.query!("SET CONSTRAINTS draws_v6_lock_commit IMMEDIATE")
        Repo.rollback(:accepted)
      end)

    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end
end
