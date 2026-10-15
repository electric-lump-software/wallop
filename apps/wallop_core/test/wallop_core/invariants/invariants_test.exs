defmodule WallopCore.Invariants.SuiteTest do
  @moduledoc """
  README: the protocol invariant suite.

  Every rule of the draw protocol that a later change could quietly break
  is pinned here as a named test. A test's name starts with its invariant's
  id, `INV-<n>`, followed by the rule, so a failure reads as the broken rule.

    * Group A, `group_a_lock_and_guard_test.exs`: the lock and the database
      guard (INV-1 to INV-6).
    * Group B, `group_b_observation_and_execution_test.exs`: the observation
      store, completion, execution and the lock action (INV-7 to INV-11,
      and INV-8b).

  The rule: an invariant that a later task delivers is written now, against
  that task's planned interface, and tagged `@tag :pending_task_<N>`. The
  tags are listed in `WallopCore.InvariantCase.pending_tags/0` and excluded
  by default in `test_helper.exs`. **Each task removes its pending tag from
  the invariants it delivers, and isn't complete until they are on and
  green.** Never delete or weaken an invariant to make a task pass; a
  failing invariant is a bug in the task.

  Run all invariants with:

      mix test --only invariant

  Pending invariants show as skipped in that run. To run one task's pending
  invariants for real, use `mix test --only pending_task_<N>`.

  Every test module here declares `@moduletag :invariant` and uses
  `WallopCore.InvariantCase`. The tests below keep the suite honest.
  """
  use ExUnit.Case, async: true

  @moduletag :invariant

  alias WallopCore.InvariantCase

  @dir __DIR__
  @ids ~w(INV-1 INV-2 INV-3 INV-4 INV-5 INV-6 INV-7 INV-8 INV-8b INV-9 INV-10 INV-11)

  defp sources do
    for path <- Path.wildcard(Path.join(@dir, "*_test.exs")),
        Path.basename(path) != "invariants_test.exs",
        do: {Path.basename(path), File.read!(path)}
  end

  defp names(source) do
    ~r/^\s*(?:test|property)\s+"([^"]*)"/m
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
  end

  test "INV-* every invariant test is named after its invariant" do
    for {file, source} <- sources(), name <- names(source) do
      assert name =~ ~r/^INV-\d+b? /, "#{file}: #{inspect(name)}"
    end
  end

  test "INV-* every invariant module is tagged :invariant and uses InvariantCase" do
    for {file, source} <- sources() do
      assert source =~ ~r/^\s*@moduletag :invariant$/m, file
      assert source =~ "use WallopCore.InvariantCase", file
    end
  end

  test "INV-* every invariant id has at least one test" do
    all = sources() |> Enum.flat_map(fn {_, source} -> names(source) end)

    for id <- @ids do
      assert Enum.any?(all, &String.starts_with?(&1, id <> " ")), "no test for #{id}"
    end
  end

  test "INV-* every pending tag in use is excluded by default" do
    used =
      sources()
      |> Enum.flat_map(fn {_, source} -> Regex.scan(~r/@tag :(pending_task_\d+)/, source) end)
      |> Enum.map(fn [_, tag] -> String.to_atom(tag) end)
      |> Enum.uniq()

    for tag <- used do
      assert tag in InvariantCase.pending_tags(), "#{tag} is not in InvariantCase.pending_tags/0"
    end

    excluded = Keyword.get(ExUnit.configuration(), :exclude, [])
    assert Enum.all?(InvariantCase.pending_tags(), &(&1 in excluded))
  end
end
