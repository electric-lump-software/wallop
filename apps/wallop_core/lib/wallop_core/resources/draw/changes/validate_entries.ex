defmodule WallopCore.Resources.Draw.Changes.ValidateEntries do
  @moduledoc """
  Validates entry structure on draw creation.

  Ensures entries conform to the protocol spec: each entry has a non-empty
  string `id` and a positive integer `weight`, with no duplicate IDs. Also
  enforces bounds to prevent resource exhaustion.
  """
  use Ash.Resource.Change

  @max_entries 10_000
  @max_weight 1_000
  @max_total_weight 100_000

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :entries) do
      nil -> changeset
      entries -> validate(changeset, entries)
    end
  end

  defp validate(changeset, entries) do
    with :ok <- validate_count(entries),
         :ok <- validate_structure(entries),
         :ok <- validate_unique_ids(entries),
         :ok <- validate_weights(entries),
         :ok <- validate_total_weight(entries) do
      changeset
    else
      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :entries, message: message)
    end
  end

  defp validate_count(entries) do
    if length(entries) > @max_entries do
      {:error, "must not exceed #{@max_entries} entries"}
    else
      :ok
    end
  end

  defp validate_structure(entries) do
    valid? =
      Enum.all?(entries, fn entry ->
        id = entry["id"] || entry[:id]
        weight = entry["weight"] || entry[:weight]

        is_binary(id) and id != "" and is_integer(weight) and weight > 0
      end)

    if valid?,
      do: :ok,
      else: {:error, "each entry must have a non-empty string id and a positive integer weight"}
  end

  defp validate_unique_ids(entries) do
    ids = Enum.map(entries, fn e -> e["id"] || e[:id] end)

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, "must not contain duplicate entry IDs"}
    end
  end

  defp validate_weights(entries) do
    valid? =
      Enum.all?(entries, fn e ->
        weight = e["weight"] || e[:weight]
        weight <= @max_weight
      end)

    if valid?, do: :ok, else: {:error, "entry weight must not exceed #{@max_weight}"}
  end

  defp validate_total_weight(entries) do
    total = Enum.reduce(entries, 0, fn e, acc -> acc + (e["weight"] || e[:weight]) end)

    if total <= @max_total_weight do
      :ok
    else
      {:error, "total weight must not exceed #{@max_total_weight}"}
    end
  end
end
