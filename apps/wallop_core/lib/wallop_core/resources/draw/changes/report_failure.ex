defmodule WallopCore.Resources.Draw.Changes.ReportFailure do
  @moduledoc """
  Logs every failed draw at error level and emits
  `[:wallop_core, :draw, :failed]`, so a failure is visible without reading
  the draws table. Runs after the transaction, and only when it committed:
  a failure that rolls back (for example because its webhook job couldn't
  be inserted) is not reported. Inside a caller's own transaction Ash runs
  this hook immediately, before that outer commit, so call `mark_failed`
  outside an enclosing transaction.
  """
  use Ash.Resource.Change

  require Logger

  alias WallopCore.Log

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, draw} ->
        report(draw)
        {:ok, draw}

      _changeset, error ->
        error
    end)
  end

  defp report(draw) do
    Logger.error("Draw #{Log.redact_id(draw.id)} failed: #{draw.failure_reason}")

    :telemetry.execute([:wallop_core, :draw, :failed], %{count: 1}, %{
      draw_id: draw.id,
      operator_id: Map.get(draw, :operator_id),
      failure_reason: draw.failure_reason
    })
  end
end
