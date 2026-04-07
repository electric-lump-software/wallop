defmodule WallopCore.Resources.Draw.Changes.AssignOperatorSequence do
  @moduledoc """
  Assigns a gap-free, monotonic per-operator sequence number at draw create
  time when the actor's api_key has an operator.

  Uses a Postgres advisory transaction lock keyed on the operator id to
  serialise concurrent creates for the same operator, then reads
  `MAX(operator_sequence)+1`. The unique index on
  `(operator_id, operator_sequence)` is the belt-and-braces backstop.

  Postgres sequences are NOT used — they leak gaps on rollback, which would
  destroy the draw-shopping signal.

  When the api_key has no operator, this change is a no-op (operator_id and
  operator_sequence stay nil — backward compatible).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn cs -> assign(cs, context.actor) end)
  end

  defp assign(changeset, nil), do: changeset

  defp assign(changeset, %{operator_id: nil}), do: changeset

  defp assign(changeset, %{operator_id: operator_id}) when is_binary(operator_id) do
    repo = WallopCore.Repo

    # Hash the operator_id into a stable int8 for advisory lock keyspace.
    {:ok, %{rows: [[lock_key]]}} =
      repo.query("SELECT ('x' || substr(md5($1), 1, 16))::bit(64)::bigint", [operator_id])

    {:ok, _} = repo.query("SELECT pg_advisory_xact_lock($1)", [lock_key])

    {:ok, %{rows: [[max_seq]]}} =
      repo.query(
        "SELECT COALESCE(MAX(operator_sequence), 0) FROM draws WHERE operator_id = $1",
        [Ecto.UUID.dump!(operator_id)]
      )

    next = max_seq + 1

    changeset
    |> Ash.Changeset.force_change_attribute(:operator_id, operator_id)
    |> Ash.Changeset.force_change_attribute(:operator_sequence, next)
  end
end
