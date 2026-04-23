defmodule WallopCore.Resources.Draw.Changes.ValidateEntries do
  @moduledoc """
  Validates a batch of entries being added to a draw.

  Entry shape: `%{weight: pos_integer()}`. Each entry gets a
  wallop-assigned UUID on insert; the operator supplies only the weight.
  """
  use Ash.Resource.Change

  import Ecto.Query

  @max_entries 10_000
  @max_weight 1_000
  @max_total_weight 100_000

  @impl true
  def change(changeset, _opts, _context) do
    entries =
      Ash.Changeset.get_argument(changeset, :entries) ||
        Ash.Changeset.get_attribute(changeset, :entries)

    case entries do
      nil -> changeset
      entries -> validate(changeset, entries)
    end
  end

  defp validate(changeset, entries) do
    draw = changeset.data

    with :ok <- validate_structure(entries),
         :ok <- validate_weights(entries),
         :ok <- validate_total_count(draw, entries),
         :ok <- validate_total_weight(draw, entries) do
      changeset
    else
      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :entries, message: message)
    end
  end

  defp validate_structure(entries) do
    valid? =
      Enum.all?(entries, fn entry ->
        weight = entry["weight"] || entry[:weight]
        is_integer(weight) and weight > 0
      end)

    if valid?,
      do: :ok,
      else: {:error, "each entry must have a positive integer weight"}
  end

  defp validate_weights(entries) do
    valid? =
      Enum.all?(entries, fn e ->
        weight = e["weight"] || e[:weight]
        weight <= @max_weight
      end)

    if valid?, do: :ok, else: {:error, "entry weight must not exceed #{@max_weight}"}
  end

  defp validate_total_count(draw, entries) do
    current = draw.entry_count || 0
    total = current + length(entries)

    if total <= @max_entries do
      :ok
    else
      {:error, "total entries must not exceed #{@max_entries}"}
    end
  end

  defp validate_total_weight(draw, entries) do
    existing_weight =
      from(e in "entries",
        where: e.draw_id == type(^draw.id, :binary_id),
        select: coalesce(sum(e.weight), 0)
      )
      |> WallopCore.Repo.one!()

    new_weight = Enum.reduce(entries, 0, fn e, acc -> acc + (e["weight"] || e[:weight]) end)

    if existing_weight + new_weight <= @max_total_weight do
      :ok
    else
      {:error, "total weight must not exceed #{@max_total_weight}"}
    end
  end
end
