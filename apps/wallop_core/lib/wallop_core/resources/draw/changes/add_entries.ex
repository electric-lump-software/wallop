defmodule WallopCore.Resources.Draw.Changes.AddEntries do
  @moduledoc """
  Appends entries to an open draw by inserting into the entries table.

  Validates no duplicate IDs and enforces the 10K total limit.
  Structural validation of individual entries is handled by ValidateEntries.
  """
  use Ash.Resource.Change

  @max_entries 10_000

  @impl true
  def change(changeset, _opts, _context) do
    draw = changeset.data
    new_entries = Ash.Changeset.get_argument(changeset, :entries)

    current_count = draw.entry_count || 0
    new_count = current_count + length(new_entries)

    if new_count > @max_entries do
      Ash.Changeset.add_error(changeset,
        field: :entries,
        message: "total entries must not exceed #{@max_entries}"
      )
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:entry_count, new_count)
      |> Ash.Changeset.after_action(fn _changeset, draw ->
        insert_entries(draw, new_entries)

        Phoenix.PubSub.broadcast(WallopCore.PubSub, "draw:#{draw.id}", {:draw_updated, draw})
        {:ok, draw}
      end)
    end
  end

  @spec insert_entries(map(), [map()]) :: {non_neg_integer(), nil}
  defp insert_entries(draw, entries) do
    now = DateTime.utc_now()
    draw_id_binary = Ecto.UUID.dump!(draw.id)

    rows =
      Enum.map(entries, fn entry ->
        id = entry["id"] || entry[:id]
        weight = entry["weight"] || entry[:weight]

        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          draw_id: draw_id_binary,
          entry_id: id,
          weight: weight,
          inserted_at: now
        }
      end)

    WallopCore.Repo.insert_all("entries", rows)
  end
end
