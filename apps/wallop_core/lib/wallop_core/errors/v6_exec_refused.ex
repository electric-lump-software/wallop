defmodule WallopCore.Errors.V6ExecRefused do
  @moduledoc """
  An observation-weather draw's stored state can't be executed or signed:
  an unknown (lock_schema_version, entropy_composition) pair, a receipt
  builder refusing the stored values, or a `fair_pick_version` that differs
  from the lock receipt's. Retrying can't change stored state, so the
  executor stops instead of retrying, and the draw is left as it is.
  """

  use Splode.Error, class: :invalid, fields: [:message]

  def message(%{message: message}), do: message
end
