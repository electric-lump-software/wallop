defmodule WallopCore.OperatorInfo do
  @moduledoc """
  Helper for fetching the operator and signed receipt associated with a draw.

  Returns `{nil, nil, nil}` for draws whose api_key has no operator (backward
  compatible — these are draws created before the operator registry existed
  or by self-hosted installations without operators).
  """

  require Ash.Query

  alias WallopCore.Resources.{
    ExecutionReceipt,
    InfrastructureSigningKey,
    Operator,
    OperatorReceipt,
    OperatorSigningKey
  }

  @doc """
  Returns `{operator, lock_receipt, execution_receipt}` for a draw.

  Returns `{nil, nil, nil}` for draws without an operator.
  """
  def for_draw(%{operator_id: nil}), do: {nil, nil, nil}

  def for_draw(%{operator_id: operator_id, id: draw_id}) when is_binary(operator_id) do
    operator = Ash.get!(Operator, operator_id, authorize?: false)

    lock_receipt =
      OperatorReceipt
      |> Ash.Query.filter(draw_id == ^draw_id)
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, r} -> r
        _ -> nil
      end

    execution_receipt =
      ExecutionReceipt
      |> Ash.Query.filter(draw_id == ^draw_id)
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, r} -> r
        _ -> nil
      end

    {operator, lock_receipt, execution_receipt}
  end

  @doc """
  Returns `{operator_public_key_hex, infra_public_key_hex}` for receipt
  verification. Looks up the operator key by the lock receipt's
  `operator_id` and `signing_key_id`, and the infrastructure key by the
  execution receipt's `signing_key_id`.

  Returns nil for a missing receipt, or for a key that doesn't exist or has
  been revoked.
  """
  def signing_keys_hex(lock_receipt, execution_receipt) do
    {operator_key_hex(lock_receipt), infrastructure_key_hex(execution_receipt)}
  end

  defp operator_key_hex(%{signing_key_id: kid, operator_id: operator_id})
       when is_binary(kid) and is_binary(operator_id) do
    OperatorSigningKey
    |> Ash.Query.filter(operator_id == ^operator_id and key_id == ^kid)
    |> public_key_hex()
  end

  defp operator_key_hex(_receipt), do: nil

  defp infrastructure_key_hex(%{signing_key_id: kid}) when is_binary(kid) do
    InfrastructureSigningKey
    |> Ash.Query.filter(key_id == ^kid)
    |> public_key_hex()
  end

  defp infrastructure_key_hex(_receipt), do: nil

  defp public_key_hex(query) do
    query
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{public_key: pk}] -> Base.encode16(pk, case: :lower)
      [] -> nil
    end
  end
end
