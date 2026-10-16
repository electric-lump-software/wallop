defmodule WallopCore.Attacks.FailMarginTest do
  @moduledoc """
  The rule "a v6 draw is never failed once drand is public" must hold even
  when the database clock lags drand.

  The observation store closes at F, at least 60 seconds before pub(R), so
  it stays blind to drand while the database clock lags by up to that much.
  A failure rule closing at pub(R) itself would have no such margin: with
  the clock L seconds behind, anyone able to set `status = 'failed'` would
  have L seconds after the real pub(R) to read the beacon, compute the
  winners and fail the draws they dislike. So both the statement check and
  the commit-time check refuse `failed` from F on, the same skew budget the
  store has. Nothing legitimate fails a v6 draw between F and pub(R).

  The commit-time half (a fail made before F, committed after it) is INV-9's
  unboxed test in `invariants/group_b_observation_and_execution_test.exs`.
  """
  use WallopCore.InvariantCase, async: false

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Weather.Schedule

  @w Schedule.fetch_window_seconds()
  @refusal "a v6 draw can't fail once its fetch deadline has passed"

  test "a v6 draw can't be failed in the last seconds before pub(R), after F" do
    {_op, key} = create_v6_operator()
    # F passed two minutes ago; drand's round publishes in 6 seconds.
    wt = DateTime.utc_now() |> DateTime.add(-(@w + 120)) |> DateTime.truncate(:second)
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 6))
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)

    assert try_sql("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
             dump(draw.id),
             NaiveDateTime.utc_now()
           ]) == @refusal
  end

  test "before F, failing a v6 draw is still allowed" do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-(@w - 600)) |> DateTime.truncate(:second)
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)

    assert try_sql_all(fn ->
             Repo.query!("UPDATE draws SET status = 'failed' WHERE id = $1", [dump(draw.id)])
             Repo.query!("SET CONSTRAINTS draws_v6_failed_commit IMMEDIATE")
           end) == nil
  end

  defp try_sql_all(fun) do
    {:error, :accepted} =
      Repo.transaction(fn ->
        fun.()
        Repo.rollback(:accepted)
      end)

    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end
end
