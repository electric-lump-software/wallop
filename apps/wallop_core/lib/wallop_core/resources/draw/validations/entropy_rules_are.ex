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

  @impl true
  def validate(changeset, opts, _context) do
    pair = %{
      lock_schema_version: Ash.Changeset.get_attribute(changeset, :lock_schema_version),
      entropy_composition: Ash.Changeset.get_attribute(changeset, :entropy_composition)
    }

    if V6Rules.rules(pair) == {:ok, opts[:rules]},
      do: :ok,
      else: {:error, field: :entropy_composition, message: "not these rules"}
  end
end
