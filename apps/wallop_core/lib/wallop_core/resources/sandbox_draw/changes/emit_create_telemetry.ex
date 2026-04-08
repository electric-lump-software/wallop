defmodule WallopCore.Resources.SandboxDraw.Changes.EmitCreateTelemetry do
  @moduledoc """
  Emits a `[:wallop_core, :sandbox_draw, :create]` telemetry event after
  a sandbox draw is created. Sandbox draws are otherwise unaudited (no
  receipt, no transparency log, no operator sequence), so emitting this
  event is the only way for operators to observe abuse or unusual volume.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      :telemetry.execute(
        [:wallop_core, :sandbox_draw, :create],
        %{count: 1, entry_count: length(record.entries || [])},
        %{
          api_key_id: record.api_key_id,
          operator_id: record.operator_id,
          winner_count: record.winner_count
        }
      )

      {:ok, record}
    end)
  end
end
