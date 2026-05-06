defmodule WallopCore.Resources.Draw.Changes.HashAndClearClientRef do
  @moduledoc """
  Hash-at-boundary for `Draw.add_entries` idempotency (ADR-0012).

  Reads the operator-supplied `client_ref` plaintext, computes the
  domain-separated `client_ref_digest` and the canonical-multiset
  `payload_digest`, stashes both in the changeset context for
  downstream changes (`CheckIdempotency`), and **deletes the plaintext
  argument from the changeset** so no subsequent telemetry, logging,
  or error path can leak it.

  This MUST be the first change in the `add_entries` action's pipeline
  (after `ValidateEntries`, before `CheckIdempotency` and `AddEntries`).
  Any change that runs before this one would see the plaintext on the
  changeset.

  Plaintext leakage regression: see
  `apps/wallop_core/test/wallop_core/resources/draw/client_ref_leakage_test.exs`.
  """
  use Ash.Resource.Change

  alias WallopCore.Protocol.ClientRef

  @impl true
  def change(changeset, _opts, _context) do
    client_ref = Ash.Changeset.get_argument(changeset, :client_ref)
    entries = Ash.Changeset.get_argument(changeset, :entries) || []
    draw = changeset.data

    cond do
      changeset.errors != [] ->
        # An earlier change (eg. ValidateEntries) already failed.
        # Don't run digest work over invalid data.
        changeset

      not is_binary(client_ref) ->
        Ash.Changeset.add_error(changeset,
          field: :client_ref,
          message: "is required and must be a string"
        )

      true ->
        try do
          client_ref_digest = ClientRef.client_ref_digest(draw.id, client_ref)
          weights = Enum.map(entries, fn e -> e["weight"] || e[:weight] end)
          payload_digest = ClientRef.payload_digest(draw.id, weights)

          changeset
          |> Ash.Changeset.put_context(:client_ref_digest, client_ref_digest)
          |> Ash.Changeset.put_context(:payload_digest, payload_digest)
          |> Ash.Changeset.delete_argument(:client_ref)
        rescue
          e in ArgumentError ->
            Ash.Changeset.add_error(changeset,
              field: :client_ref,
              message: argument_error_message(e)
            )
        end
    end
  end

  # Sanitise the ArgumentError message before surfacing as a changeset
  # error. The protocol module's messages reference the cap and
  # validation rules without echoing the plaintext, so they're safe
  # to surface, but we strip any "got: ..." tail defensively in case
  # a future protocol change adds plaintext to the message.
  defp argument_error_message(%ArgumentError{message: msg}) do
    msg
    |> String.replace(~r/, got:.*$/s, "")
    |> String.replace(~r/^.*: /, "")
  end
end
