defmodule WallopCore.Resources.Draw.Validations.NoEntropyDeclared do
  @moduledoc """
  Rejects execution via caller-provided seed when entropy sources have been declared.

  When `drand_round` is set on the draw, it means the draw is participating in the
  commit-reveal entropy protocol. The seed must be derived from public entropy sources
  (drand + weather), not supplied by the caller.

  The DB trigger enforces this constraint as a hard invariant. This validation provides
  an earlier, friendlier error at the Ash layer before hitting the database.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    draw = changeset.data

    if draw.drand_round != nil do
      {:error,
       field: :seed, message: "cannot use caller-provided seed when entropy sources are declared"}
    else
      :ok
    end
  end
end
