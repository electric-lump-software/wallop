defmodule WallopCore.Resources.Draw.Validations.LockSchemaIs do
  @moduledoc """
  Condition for the lock's changes: true when the lock schema version that
  `WallopCore.Resources.Draw.Changes.ResolveLockSchema` recorded on the
  changeset equals the `version` option (`nil` for the forecast path).

  Used only in `where:` clauses, so each lock path runs exactly the changes
  of its own protocol and never the other's.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} when is_nil(version) or is_binary(version) -> {:ok, opts}
      _ -> {:error, "LockSchemaIs needs a `version` option: nil or a string"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :lock_schema_version) == opts[:version],
      do: :ok,
      else: {:error, field: :lock_schema_version, message: "not this protocol"}
  end
end
