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
  verification. Looks up signing keys by the `signing_key_id` on each receipt.

  Returns nils for missing receipts or keys.
  """
  def signing_keys_hex(lock_receipt, execution_receipt) do
    op_key_hex =
      case lock_receipt do
        %{signing_key_id: kid} when is_binary(kid) ->
          OperatorSigningKey
          |> Ash.Query.filter(key_id == ^kid)
          |> Ash.Query.limit(1)
          |> Ash.read!(authorize?: false)
          |> case do
            [%{public_key: pk}] -> Base.encode16(pk, case: :lower)
            [] -> nil
          end

        _ ->
          nil
      end

    infra_key_hex =
      case execution_receipt do
        %{signing_key_id: kid} when is_binary(kid) ->
          InfrastructureSigningKey
          |> Ash.Query.filter(key_id == ^kid)
          |> Ash.Query.limit(1)
          |> Ash.read!(authorize?: false)
          |> case do
            [%{public_key: pk}] -> Base.encode16(pk, case: :lower)
            [] -> nil
          end

        _ ->
          nil
      end

    {op_key_hex, infra_key_hex}
  end
end
