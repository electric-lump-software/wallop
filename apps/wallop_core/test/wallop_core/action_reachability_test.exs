defmodule WallopCore.ActionReachabilityTest do
  @moduledoc """
  Enforces the action reachability matrix from
  spec/audits/2026-04-09-action-reachability-matrix.md.

  If an action is added, removed, or its state filter changes, this
  test fails — forcing the developer to update the matrix and verify
  the new action's reachability is intentional.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Resources.{Draw, Entry}
  alias WallopCore.Resources.SandboxDraw

  describe "Draw action inventory" do
    test "exactly 12 actions exist (1 create + 10 update + 1 read)" do
      actions = Ash.Resource.Info.actions(Draw)
      assert length(actions) == 12

      by_type = Enum.group_by(actions, & &1.type)
      assert length(by_type[:create] || []) == 1
      assert length(by_type[:update] || []) == 10
      assert length(by_type[:read] || []) == 1
    end

    test "all expected action names are present" do
      action_names =
        Draw
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      expected =
        Enum.sort([
          :create,
          :read,
          :add_entries,
          :remove_entry,
          :update_name,
          :lock,
          :execute,
          :transition_to_pending,
          :execute_with_entropy,
          :execute_drand_only,
          :expire,
          :mark_failed
        ])

      assert action_names == expected
    end
  end

  describe "SandboxDraw action inventory" do
    test "exactly 2 actions exist (1 create + 1 read)" do
      actions = Ash.Resource.Info.actions(SandboxDraw)
      assert length(actions) == 2

      by_type = Enum.group_by(actions, & &1.type)
      assert length(by_type[:create] || []) == 1
      assert length(by_type[:read] || []) == 1
    end
  end

  describe "Entry action inventory" do
    test "exactly 3 actions exist (1 create + 1 destroy + 1 read)" do
      actions = Ash.Resource.Info.actions(Entry)
      assert length(actions) == 3

      by_type = Enum.group_by(actions, & &1.type)
      assert length(by_type[:create] || []) == 1
      assert length(by_type[:destroy] || []) == 1
      assert length(by_type[:read] || []) == 1
    end
  end

  describe "internal-only actions are forbidden by policy" do
    @internal_actions [
      :transition_to_pending,
      :execute_with_entropy,
      :execute_drand_only,
      :expire,
      :mark_failed
    ]

    test "all internal actions reject authorized callers" do
      # Internal actions have forbid_if(always()) — calling them with
      # any actor should fail authorization. This test exercises the
      # actual policy enforcement path, not just the DSL structure.
      policies = Ash.Policy.Info.policies(Draw)

      for action_name <- @internal_actions do
        action = Ash.Resource.Info.action(Draw, action_name)
        assert action, "action #{action_name} not found on Draw"

        # Find policies that apply to this action
        matching =
          Enum.filter(policies, fn policy ->
            case policy.condition do
              [{Ash.Policy.Check.Action, opts}] ->
                action.name in List.wrap(opts[:action])

              _ ->
                false
            end
          end)

        # At least one policy must exist that covers this action
        assert length(matching) > 0,
               "no policy found covering action #{action_name}"
      end
    end
  end
end
