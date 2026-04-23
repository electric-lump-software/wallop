defmodule WallopCore.Resources.Draw.Changes.AddEntries do
  @moduledoc """
  Appends entries to an open draw by creating Entry records.

  Each entry gets a server-generated UUID (the Ash PK `id`, from Postgres
  `gen_random_uuid()`). Structural validation is handled by
  `ValidateEntries`.
  """
  use Ash.Resource.Change

  alias WallopCore.Resources.Entry

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

        WallopCore.DrawPubSub.broadcast(draw)
        {:ok, draw}
      end)
    end
  end

  @spec insert_entries(map(), [map()]) :: :ok
  defp insert_entries(draw, entries) do
    inputs =
      Enum.map(entries, fn entry ->
        %{
          draw_id: draw.id,
          weight: entry["weight"] || entry[:weight]
        }
      end)

    Ash.bulk_create!(inputs, Entry, :create, authorize?: false)

    :ok
  end
end
