defmodule WallopCore.Attacks.FreqStoreStraddleTest do
  @moduledoc """
  The frequency store in real transactions that really commit:

    * an insert whose statement runs before F but whose commit lands after
      F is refused at commit, and nothing is stored (with a control that
      commits in time);
    * a completion that arrives while T's window insert is uncommitted
      waits on the draw's row lock and then reads the store afresh, so it
      can't fall back past a window that commits first (with a control in
      which the insert rolls back).

  The inserts are raw: `Windows.store/3` refuses to run inside a caller's
  transaction, and the point is to hold one open.
  """
  use ExUnit.Case, async: false

  import WallopCore.TestHelpers
  import WallopCore.UnboxedHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Protocol.Tags.Freq
  alias WallopCore.Repo

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
  @blocked_ms 300

  setup do
    {operator, key} = unboxed(fn -> create_freq_operator() end)
    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    %{key: key}
  end

  defp draw(key, t, pub_offset, status \\ "awaiting_entropy") do
    unboxed(fn ->
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), pub_offset))
      d = put_freq_awaiting!(open_draw_with_entries(key), t, round)
      Repo.query!("UPDATE draws SET status = $2 WHERE id = $1", [Ecto.UUID.dump!(d.id), status])
      d
    end)
  end

  defp insert(t) do
    fn ->
      Repo.query!(
        "INSERT INTO frequency_windows (id, freq_start, value, raw) VALUES (gen_random_uuid(), $1, $2, '{}')",
        [DateTime.to_naive(t), @value]
      )
    end
  end

  defp stored(t),
    do:
      unboxed(fn ->
        Repo.query!("SELECT count(*) FROM frequency_windows WHERE freq_start = $1", [
          DateTime.to_naive(t)
        ]).rows
      end)

  # A T on the 15 s grid whose F is 3 to 18 s away.
  defp t_closing_soon do
    now = DateTime.to_unix(DateTime.utc_now())
    lead = Schedule.span_seconds() + Schedule.fetch_window_seconds() - 3
    t = now - lead + Integer.mod(-(now - lead), 15)
    DateTime.from_unix!(t * 1_000_000, :microsecond)
  end

  describe "the commit-time check" do
    @tag :slow
    test "an insert run before F and committed after F is refused at commit", %{key: key} do
      t = t_closing_soon()
      draw(key, t, 3600)
      t1 = in_transaction(insert(t))
      assert_receive {:done_statement, ^t1}, 5_000

      unboxed(fn -> wait_until_db_clock_after(Schedule.fetch_deadline(t)) end)
      send(t1, :commit)

      assert_receive {:result, ^t1,
                      {:refused, "a frequency window must commit by its fetch deadline"}},
                     5_000

      assert stored(t) == [[0]]
    end

    test "control: an insert committed before F is stored once", %{key: key} do
      t = aligned_freq_start(-(Schedule.span_seconds() + 60))
      draw(key, t, 3600)
      t1 = in_transaction(insert(t))
      assert_receive {:done_statement, ^t1}, 5_000
      send(t1, :commit)
      assert_receive {:result, ^t1, :committed}, 5_000
      assert stored(t) == [[1]]
    end
  end

  describe "a completion during an uncommitted window insert" do
    test "waits, then reads the stored window", %{key: key} do
      t = aligned_freq_start(-(Schedule.span_seconds() + 60))
      d = draw(key, t, -10, "pending_entropy")

      t1 = in_transaction(insert(t))
      assert_receive {:done_statement, ^t1}, 5_000

      t2 =
        in_transaction(fn ->
          Repo.query!(
            "UPDATE draws SET status = 'completed', executed_at = $2, freq_fallback_reason = $3 WHERE id = $1",
            [Ecto.UUID.dump!(d.id), NaiveDateTime.utc_now(), Freq.fallback_reason()]
          )
        end)

      refute_receive {:done_statement, ^t2}, @blocked_ms
      send(t1, :commit)
      assert_receive {:result, ^t1, :committed}, 5_000

      # Had the guard read the store before the row lock, it would have
      # found nothing and refused for the deadline instead.
      assert_receive {:result, ^t2,
                      {:refused, "v6 draw must complete with its stored frequency window"}},
                     5_000
    end

    test "control: if the insert rolls back, the completion is judged on an empty store", %{
      key: key
    } do
      t = aligned_freq_start(-(Schedule.span_seconds() + 60))
      d = draw(key, t, -10, "pending_entropy")

      t1 = in_transaction(insert(t))
      assert_receive {:done_statement, ^t1}, 5_000

      t2 =
        in_transaction(fn ->
          Repo.query!(
            "UPDATE draws SET status = 'completed', executed_at = $2, freq_fallback_reason = $3 WHERE id = $1",
            [Ecto.UUID.dump!(d.id), NaiveDateTime.utc_now(), Freq.fallback_reason()]
          )
        end)

      refute_receive {:done_statement, ^t2}, @blocked_ms
      send(t1, :rollback)
      assert_receive {:result, ^t1, :rolled_back}, 5_000

      # F hasn't passed (the window is open), so the empty store still refuses.
      assert_receive {:result, ^t2,
                      {:refused,
                       "v6 draw may fall back only after the fetch deadline with nothing stored"}},
                     5_000
    end
  end
end
