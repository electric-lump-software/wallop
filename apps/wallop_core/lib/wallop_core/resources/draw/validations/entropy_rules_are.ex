defmodule WallopCore.Resources.Draw.Validations.EntropyRulesAre do
  @moduledoc """
  Condition for the lock's changes: true when the (lock_schema_version,
  entropy_composition) pair that
  `WallopCore.Resources.Draw.Changes.ResolveLockSchema` recorded on the
  changeset selects the `rules` option's rules
  (`WallopCore.Entropy.V6Rules.rules/1`).

  Used only in `where:` clauses, so each tag's lock runs exactly its own
  changes and never another tag's.
  """
  use Ash.Resource.Validation

  alias WallopCore.Entropy.V6Rules

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} when rules in [:landobs, :freq] -> {:ok, opts}
      _ -> {:error, "EntropyRulesAre needs a `rules` option: :landobs or :freq"}
    end
  end

  @doc """
  The (lock_schema_version, entropy_composition) pair recorded on a lock
  changeset, shaped for `V6Rules.rules/1`. The lock's condition, its
  `DrawAt` validation and its signer all read the pair through this.
  """
  @spec pair(Ash.Changeset.t()) :: %{lock_schema_version: term(), entropy_composition: term()}
  def pair(changeset),
    do: %{
      lock_schema_version: Ash.Changeset.get_attribute(changeset, :lock_schema_version),
      entropy_composition: Ash.Changeset.get_attribute(changeset, :entropy_composition)
    }

  @impl true
  def validate(changeset, opts, _context) do
    if V6Rules.rules(pair(changeset)) == {:ok, opts[:rules]},
      do: :ok,
      else: {:error, field: :entropy_composition, message: "not these rules"}
  end
end
