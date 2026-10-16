defmodule WallopCore.Resources.Draw.Changes.ResolveLockSchema do
  @moduledoc """
  Reads the operator's draw protocol at lock and records it on the draw:
  lock schema "6" with the Land Observations entropy composition for an
  observation operator, lock schema "6" with the grid-frequency entropy
  composition for a frequency operator, nothing for a forecast one.

  Everything after this in the lock (the entropy declaration, the receipt,
  the jobs) follows the recorded value, never the operator's current flag.
  Once the draw has left open the pair is frozen by the database, and
  execution and verification read it from the draw, never from the operator.

  The flag is read when the changeset is built, so the lock's `where:`
  conditions can route on it. For a schema 6 lock it is read again inside
  the lock transaction, with a share lock on the operator row, and the
  lock is refused unless the operator is still on the protocol this lock
  recorded (the caller can retry). So a draw is only ever locked under a
  tag while its operator is on that tag's protocol. A forecast lock does
  no second read: it
  stays exactly as it was before schema 6 existed, and a forecast draw
  locked while the flag moves is a valid forecast draw.
  """
  use Ash.Resource.Change

  alias WallopCore.Protocol
  alias WallopCore.Resources.Operator

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data.operator_id do
      nil ->
        changeset

      operator_id ->
        case Ash.get(Operator, operator_id, authorize?: false) do
          {:ok, operator} ->
            record(changeset, protocol(operator), operator_id)

          # Never guess a protocol: an unreadable operator refuses the lock.
          {:error, _} ->
            Ash.Changeset.add_error(changeset,
              field: :operator_id,
              message: "could not read the draw's operator"
            )
        end
    end
  end

  defp protocol(%{draw_protocol: :observation}), do: :observation
  defp protocol(%{draw_protocol: :frequency}), do: :frequency
  defp protocol(_), do: :forecast

  defp record(changeset, protocol, operator_id) when protocol in [:observation, :frequency] do
    changeset
    |> Ash.Changeset.force_change_attribute(:lock_schema_version, "6")
    |> Ash.Changeset.force_change_attribute(:entropy_composition, tag(protocol))
    |> Ash.Changeset.before_action(&confirm(&1, operator_id, protocol))
  end

  defp record(changeset, :forecast, _operator_id), do: changeset

  defp tag(:observation), do: Protocol.landobs_entropy_composition()
  defp tag(:frequency), do: Protocol.freq_entropy_composition()

  # In the lock transaction: the operator must still be on the protocol this
  # lock recorded. FOR SHARE makes a concurrent flag change wait for it.
  defp confirm(changeset, operator_id, protocol) do
    current =
      Operator
      |> Ash.Query.filter(id == ^operator_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one(authorize?: false)

    if match?({:ok, %{draw_protocol: ^protocol}}, current) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :draw_protocol,
        message: "the operator's draw protocol changed during the lock; try again"
      )
    end
  end
end
