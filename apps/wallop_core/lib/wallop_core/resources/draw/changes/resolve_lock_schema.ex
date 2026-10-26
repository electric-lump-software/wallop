defmodule WallopCore.Resources.Draw.Changes.ResolveLockSchema do
  @moduledoc """
  Reads the operator's draw protocol at lock and records it on the draw:
  lock schema "6" with the Land Observations entropy composition for an
  observation operator, lock schema "6" with the grid-frequency entropy
  composition for a frequency operator.

  Every lock is a lock schema 6 lock. An unreadable operator, or one on
  any other protocol, is refused (an operator can't be on another one: the
  database allows only these two, and refuses any lock without lock
  schema 6). A draw with no operator is refused where its receipt would
  be signed.

  Everything after this in the lock (the entropy declaration, the receipt,
  the jobs) follows the recorded value, never the operator's current flag.
  Once the draw has left open the pair is frozen by the database, and
  execution and verification read it from the draw, never from the operator.

  The flag is read when the changeset is built, so the lock's `where:`
  conditions can route on it. It is read again inside the lock
  transaction, with a share lock on the operator row, and the lock is
  refused unless the operator is still on the protocol this lock recorded
  (the caller can retry). So a draw is only ever locked under a tag while
  its operator is on that tag's protocol.

  An observation lock is refused unless the service that fetches Land
  Observations readings has recently said it holds a usable key
  (`WallopCore.Weather.ObservationReadiness.ready?/0`, read from the
  database, since the lock may run in another service): otherwise no
  reading could be fetched, and every such draw would fall back by design.
  The refusal is an action-level `Ash.Error.Changes.InvalidArgument` (a
  JSON:API `400` `invalid_argument` with no pointer), and the draw stays
  open. Grid-frequency locks don't depend on the key.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias WallopCore.Protocol
  alias WallopCore.Resources.Operator
  alias WallopCore.Weather.ObservationReadiness

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data.operator_id do
      # Refused when the receipt is signed (SignAndStoreReceipt).
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
  defp protocol(_), do: :unknown

  defp record(changeset, protocol, operator_id) when protocol in [:observation, :frequency] do
    changeset
    |> Ash.Changeset.force_change_attribute(:lock_schema_version, "6")
    |> Ash.Changeset.force_change_attribute(:entropy_composition, tag(protocol))
    |> Ash.Changeset.before_action(&confirm(&1, operator_id, protocol))
    |> require_ready(protocol)
  end

  # Unreachable while the database allows only the two protocols above; a
  # clean 400 rather than a database exception if it ever isn't.
  defp record(changeset, :unknown, _operator_id) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(field: nil, message: "unknown draw protocol")
    )
  end

  # The lock is still recorded as schema 6, so the rest of the action
  # follows the schema 6 path; the error stops it before anything is written.
  defp require_ready(changeset, :observation) do
    if ObservationReadiness.ready?() do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(
          field: nil,
          message:
            "observation-weather draws are paused here: Land Observations readings can't be fetched right now"
        )
      )
    end
  end

  defp require_ready(changeset, :frequency), do: changeset

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
