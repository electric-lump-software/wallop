defmodule WallopCore.Resources.Draw.Changes.AddEntries do
  @moduledoc """
  Appends entries to an open draw.

  Validates no duplicate IDs against existing entries and enforces the 10K total limit.
  Structural validation of individual entries is handled by ValidateEntries.
  """
  use Ash.Resource.Change

  @max_entries 10_000

  @impl true
  def change(changeset, _opts, _context) do
    draw = changeset.data
    new_entries = Ash.Changeset.get_argument(changeset, :entries)

    existing = draw.entries || []
    combined = existing ++ new_entries

    with :ok <- validate_limit(combined),
         :ok <- validate_no_duplicates(existing, new_entries) do
      changeset
      |> Ash.Changeset.force_change_attribute(:entries, combined)
      |> Ash.Changeset.after_action(fn _changeset, draw ->
        Phoenix.PubSub.broadcast(WallopCore.PubSub, "draw:#{draw.id}", {:draw_updated, draw})
        {:ok, draw}
      end)
    else
      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :entries, message: message)
    end
  end

  defp validate_limit(combined) do
    if length(combined) > @max_entries do
      {:error, "total entries must not exceed #{@max_entries}"}
    else
      :ok
    end
  end

  defp validate_no_duplicates(existing, new_entries) do
    existing_ids = MapSet.new(existing, fn e -> e["id"] || e[:id] end)
    new_ids = Enum.map(new_entries, fn e -> e["id"] || e[:id] end)

    dupes_against_existing = Enum.filter(new_ids, &MapSet.member?(existing_ids, &1))
    dupes_within_new = new_ids -- Enum.uniq(new_ids)

    cond do
      dupes_against_existing != [] ->
        {:error, "duplicate entry IDs: #{Enum.join(dupes_against_existing, ", ")}"}

      dupes_within_new != [] ->
        {:error,
         "duplicate entry IDs within batch: #{Enum.join(Enum.uniq(dupes_within_new), ", ")}"}

      true ->
        :ok
    end
  end
end
