defmodule WallopCore.Resources.SandboxDraw.Changes.ExecuteWithSandboxSeed do
  @moduledoc """
  Runs `FairPick.draw/3` against the published sandbox seed and stamps
  the results, seed, entries and `executed_at` onto the new row in the
  same transaction the row is created in.

  There is no separate execute action. Sandbox draws are born complete —
  the attack surface the previous design exposed was precisely the window
  between "create" and "execute" that real draws have. Sandbox has no
  such window.
  """
  use Ash.Resource.Change

  alias WallopCore.Resources.SandboxDraw

  @impl true
  def change(%Ash.Changeset{valid?: false} = changeset, _opts, _context) do
    changeset
  end

  def change(changeset, _opts, _context) do
    entries_arg = Ash.Changeset.get_argument(changeset, :entries) || []

    stored_entries =
      Enum.map(entries_arg, fn e ->
        %{
          "id" => e["id"] || e[:id],
          "weight" => e["weight"] || e[:weight]
        }
      end)

    fair_pick_entries =
      Enum.map(stored_entries, fn e ->
        %{id: e["id"], weight: e["weight"]}
      end)

    seed_bytes = Base.decode16!(SandboxDraw.seed_hex(), case: :lower)

    winner_count = Ash.Changeset.get_attribute(changeset, :winner_count) || 1

    cond do
      stored_entries == [] ->
        Ash.Changeset.add_error(changeset,
          field: :entries,
          message: "must include at least one entry"
        )

      winner_count > length(stored_entries) ->
        Ash.Changeset.add_error(changeset,
          field: :winner_count,
          message: "winner_count must not exceed the number of entries"
        )

      true ->
        results = FairPick.draw(fair_pick_entries, seed_bytes, winner_count)

        string_results =
          Enum.map(results, fn %{position: pos, entry_id: id} ->
            %{"position" => pos, "entry_id" => id}
          end)

        changeset
        |> Ash.Changeset.force_change_attribute(:entries, stored_entries)
        |> Ash.Changeset.force_change_attribute(:results, string_results)
        |> Ash.Changeset.force_change_attribute(:seed, SandboxDraw.seed_hex())
        |> Ash.Changeset.force_change_attribute(:executed_at, DateTime.utc_now())
    end
  end
end
