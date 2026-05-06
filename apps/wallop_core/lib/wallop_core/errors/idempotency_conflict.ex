defmodule WallopCore.Errors.IdempotencyConflict do
  @moduledoc """
  Raised when an `add_entries` retry presents the same `client_ref`
  digest with a different `payload_digest` — i.e. the operator
  re-used an idempotency key against a logically different batch.
  Maps to HTTP 409 Conflict (ADR-0012).
  """

  use Splode.Error, class: :invalid, fields: [:field, :message]

  def message(%{message: message}), do: message

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error) do
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 409,
        code: "idempotency_conflict",
        title: "IdempotencyConflict",
        detail: error.message,
        source_pointer: "/data/attributes/client_ref",
        meta: %{}
      }
    end
  end
end
