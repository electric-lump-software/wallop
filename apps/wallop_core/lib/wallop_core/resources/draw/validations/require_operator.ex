defmodule WallopCore.Resources.Draw.Validations.RequireOperator do
  @moduledoc """
  Rejects draw creation when the API key has no operator.

  A draw without an operator cannot participate in the proof protocol:
  no operator signing key is available at lock time, so no lock receipt
  is created. Without a lock receipt, no execution receipt can chain
  from it. The draw "completes" with zero cryptographic attestation.

  This must be a hard failure, not a silent skip.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(_changeset, _opts, context) do
    case context.actor do
      %{operator_id: nil} ->
        {:error,
         field: :api_key_id, message: "API key must belong to an operator to create draws"}

      %{operator_id: id} when is_binary(id) ->
        :ok

      _ ->
        {:error,
         field: :api_key_id, message: "API key must belong to an operator to create draws"}
    end
  end
end
