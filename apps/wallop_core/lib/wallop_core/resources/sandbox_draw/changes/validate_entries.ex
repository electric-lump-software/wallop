defmodule WallopCore.Resources.SandboxDraw.Changes.ValidateEntries do
  @moduledoc """
  Validates the entries supplied to a sandbox draw create.

  Forked deliberately from `WallopCore.Resources.Draw.Changes.ValidateEntries`
  rather than shared via a flag — per Colin's review on PAM-670, sharing a
  validator between real and sandbox draws is exactly the kind of seam that
  lets the two concepts re-merge. Sandbox validation must never reach into
  real-draw state (entry counts, existing weight queries, etc).

  Rules (a subset of the real Draw validator, sandbox-only):
    * structure: each entry has a non-empty string id and positive integer weight
    * id format: alphanumeric + `_-:.=` (no PII patterns)
    * weight ≤ 1_000 per entry
    * no duplicate ids within the batch
    * count ≤ 10_000
    * total weight ≤ 100_000
  """
  use Ash.Resource.Change

  @max_entries 10_000
  @max_weight 1_000
  @max_total_weight 100_000

  # Alphanumeric, hyphens, underscores, dots, colons, equals (for base64).
  # No @, no spaces, no slashes — blocks emails, phone numbers, most PII.
  @valid_entry_id_pattern ~r/^[a-zA-Z0-9_\-:.=]+$/

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :entries) do
      nil ->
        Ash.Changeset.add_error(changeset, field: :entries, message: "entries is required")

      entries when is_list(entries) ->
        with :ok <- validate_structure(entries),
             :ok <- validate_entry_id_format(entries),
             :ok <- validate_weights(entries),
             :ok <- validate_batch_unique_ids(entries),
             :ok <- validate_total_count(entries),
             :ok <- validate_total_weight(entries) do
          changeset
        else
          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: :entries, message: message)
        end

      _ ->
        Ash.Changeset.add_error(changeset, field: :entries, message: "entries must be a list")
    end
  end

  defp validate_structure(entries) do
    valid? =
      Enum.all?(entries, fn entry ->
        id = entry["id"] || entry[:id]
        weight = entry["weight"] || entry[:weight]

        is_binary(id) and id != "" and is_integer(weight) and weight > 0
      end)

    if valid? do
      :ok
    else
      {:error, "each entry must have a non-empty string id and a positive integer weight"}
    end
  end

  defp validate_entry_id_format(entries) do
    invalid =
      entries
      |> Enum.map(fn e -> e["id"] || e[:id] end)
      |> Enum.reject(&Regex.match?(@valid_entry_id_pattern, &1))

    case invalid do
      [] ->
        :ok

      [first | _] ->
        {:error,
         "entry ID #{inspect(first)} contains invalid characters — " <>
           "use only alphanumeric characters, hyphens, underscores, dots, colons, and equals signs. " <>
           "Do not use email addresses, phone numbers, or other personally identifiable information"}
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

  defp validate_batch_unique_ids(entries) do
    ids = Enum.map(entries, fn e -> e["id"] || e[:id] end)

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, "must not contain duplicate entry IDs within batch"}
    end
  end

  defp validate_total_count(entries) do
    if length(entries) <= @max_entries do
      :ok
    else
      {:error, "total entries must not exceed #{@max_entries}"}
    end
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
