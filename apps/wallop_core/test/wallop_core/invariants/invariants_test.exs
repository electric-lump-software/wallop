defmodule WallopCore.Invariants.SuiteTest do
  @moduledoc """
  README: the protocol invariant suite.

  Every rule of the draw protocol that a later change could quietly break
  is pinned here as a named test. A test's name starts with its invariant's
  id, `INV-<n>`, followed by the rule, so a failure reads as the broken rule.

    * Group A, `group_a_lock_and_guard_test.exs`: the lock and the database
      guard (INV-1 to INV-6), and no commit deferred past drand (INV-12,
      INV-13).
    * Group B, `group_b_observation_and_execution_test.exs`: the observation
      store, completion, execution and the lock action (INV-7 to INV-11,
      and INV-8b).
    * Tamper, `tamper_test.exs`: every signed lock v6 / execution v5 field,
      mutated one step at a time and in pairs, is refused by the builder,
      the database or (through `spec/vectors/proof-bundle-v6-tamper.json`)
      the verifier (INV-2), and raw SQL attack sequences in every order.

  The rule: an invariant that a later task delivers is written now, against
  that task's planned interface, and tagged `@tag :pending_task_<N>` on the
  `test` itself (never `@describetag`, `@moduletag` or on a `property`). The
  tags are listed in `WallopCore.InvariantCase.pending_tags/0` and excluded
  by default in `test_helper.exs`. **Each task removes its pending tag from
  the invariants it delivers, and isn't complete until they are on and
  green.** Never delete or weaken an invariant to make a task pass; a
  failing invariant is a bug in the task.

  Run all live invariants with the folder's path, from the umbrella root:

      mix test apps/wallop_core/test/wallop_core/invariants

  (or `mix test test/wallop_core/invariants` from `apps/wallop_core`). A
  path adds no include, so the pending tags stay excluded. Don't use
  `--only invariant`: ExUnit lets an include beat an exclude, so it would
  also run the pending invariants. To run one task's pending invariants,
  use `mix test --only pending_task_<N>`.

  Once a task's code exists, a test below fails until its pending tags are
  removed, so a landed task can't leave its invariants switched off.

  Every test module here declares `@moduletag :invariant` and uses
  `WallopCore.InvariantCase`. The tests below keep the suite honest.
  """
  use ExUnit.Case, async: true

  @moduletag :invariant

  alias Ash.Resource.Info
  alias WallopCore.InvariantCase
  alias WallopCore.ProofBundle
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.Observations

  @dir __DIR__
  @ids ~w(INV-1 INV-2 INV-3 INV-4 INV-5 INV-6 INV-7 INV-8 INV-8b INV-9 INV-10 INV-11 INV-12 INV-13)

  defp sources do
    for path <- Path.wildcard(Path.join(@dir, "*_test.exs")),
        Path.basename(path) != "invariants_test.exs",
        do: {Path.basename(path), File.read!(path)}
  end

  defp used_pending_tags do
    sources()
    |> Enum.flat_map(fn {_, source} -> Regex.scan(~r/@tag :(pending_task_\d+)/, source) end)
    |> Enum.map(fn [_, tag] -> String.to_atom(tag) end)
    |> Enum.uniq()
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
    for tag <- used_pending_tags() do
      assert tag in InvariantCase.pending_tags(), "#{tag} is not in InvariantCase.pending_tags/0"
    end

    excluded = Keyword.get(ExUnit.configuration(), :exclude, [])
    assert Enum.all?(InvariantCase.pending_tags(), &(&1 in excluded))
  end

  test "INV-* a pending tag is set only as @tag :pending_task_N on a test" do
    for {file, source} <- sources() do
      lines = String.split(source, "\n")

      for {line, i} <- Enum.with_index(lines),
          line =~ ~r/pending_task_\d/ do
        assert line =~ ~r/^\s*@tag :pending_task_\d+$/, "#{file}:#{i + 1}: #{String.trim(line)}"

        next =
          lines
          |> Enum.drop(i + 1)
          |> Enum.drop_while(&(&1 =~ ~r/^\s*@tag /))
          |> List.first("")

        assert next =~ ~r/^\s*test "/,
               "#{file}:#{i + 1}: a pending tag must sit directly on a test, not #{String.trim(next)}"
      end
    end
  end

  # What each pending task delivers: once it exists, that task has landed.
  defp landed?(:pending_task_6), do: Code.ensure_loaded?(Observations)

  # The executor and its worker (ObservationDrawWorker) landed before the
  # database backstop, and their invariants are on. The pending_task_10 tags
  # left are the backstop's, so the marker is its pinned refusal in the
  # draws guard: `can''t` in a single-quoted literal, `can't` if dollar-quoted.
  defp landed?(:pending_task_10) do
    Draw
    |> AshPostgres.DataLayer.Info.custom_statements()
    |> Enum.any?(&(&1.up =~ ~r/can'?'t fail once its fetch deadline has passed/))
  end

  defp landed?(:pending_task_11),
    do: Enum.any?(Info.action(Draw, :lock).arguments, &(&1.name == :draw_at))

  defp landed?(:pending_task_13),
    do: Code.ensure_loaded?(ProofBundle) and function_exported?(ProofBundle, :assemble, 1)

  test "INV-* a landed task has removed its pending tags" do
    used = used_pending_tags()

    for tag <- InvariantCase.pending_tags(), tag in used, landed?(tag) do
      "pending_task_" <> n = Atom.to_string(tag)
      flunk("task #{n} has landed; remove its pending tags")
    end
  end
end
