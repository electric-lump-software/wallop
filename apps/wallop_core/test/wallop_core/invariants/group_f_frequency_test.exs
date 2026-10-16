defmodule WallopCore.Invariants.FrequencyTest do
  @moduledoc """
  Group F: the protocol invariants of the grid-frequency tag
  (`drand-quicknet+elexon-freq-v1`, lock schema 6 / execution schema 5).
  Each is written now and tagged `:pending_task_F<n>`; its task removes the
  tag and fills in the body. See `WallopCore.Invariants.SuiteTest` for the
  suite's rules.
  """
  use WallopCore.InvariantCase, async: false

  @moduletag :invariant

  @tag :pending_task_F6
  test "INV-F1 one write-once window per T; every draw of T completes with it or the fallback" do
    flunk("switched on by Task F6")
  end

  @tag :pending_task_F6
  test "INV-F2 completion equals the stored window or the fallback rule, and executed_at >= pub(R)" do
    flunk("switched on by Task F6")
  end

  @tag :pending_task_F6
  test "INV-F3 no fallback until F + M, a stored window commits by F, and no fail from F" do
    flunk("switched on by Task F6")
  end

  @tag :pending_task_F5
  test "INV-F4 the signed freq_start, locked_at, drand_round and drand_chain equal the row, in either order" do
    flunk("switched on by Task F5")
  end

  @tag :pending_task_F5
  test "INV-F5 SQL frequency timing equals Elixir under a non-UTC session" do
    flunk("switched on by Task F5")
  end

  @tag :pending_task_F9
  test "INV-F6 an unknown (schema, tag) pair is refused everywhere; frequency never falls through to Land Obs" do
    flunk("switched on by Task F9")
  end

  @tag :pending_task_F9
  test "INV-F7 a grid-frequency draw is never marked failed once its F has passed" do
    flunk("switched on by Task F9")
  end
end
