defmodule WallopCore.Errors.V6NotYet do
  @moduledoc """
  An observation-weather draw isn't due yet: its fetch window is still open
  or its drand round hasn't published. Nothing was written; the executor
  waits and tries again.
  """

  use Splode.Error, class: :invalid, fields: [:message, :retry_at]

  def message(%{message: message}), do: message
end
