defmodule WallopCore.OperatorInfo do
  @moduledoc """
  Helper for fetching the operator and signed receipt associated with a draw.

  Returns `{nil, nil}` for draws whose api_key has no operator (backward
  compatible — these are draws created before the operator registry existed
  or by self-hosted installations without operators).
  """

  require Ash.Query

  alias WallopCore.Resources.{ExecutionReceipt, Operator, OperatorReceipt}

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
end
