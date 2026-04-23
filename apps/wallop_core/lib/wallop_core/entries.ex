defmodule WallopCore.Entries do
  @moduledoc """
  Shared utilities for working with draw entries.
  """

  require Ash.Query

  alias WallopCore.Resources.Entry

  @doc """
  Load all entries for a draw from the entries table as atom-keyed maps
  shaped for `WallopCore.Protocol.entry_hash/1` and `FairPick.draw/3`.

  Returns `[%{uuid, weight}]`. The `uuid` field is the Ash primary key —
  the public UUID bound into `entry_hash`. Callers that need FairPick's
  `[%{id, weight}]` shape should map `%{id: e.uuid, weight: e.weight}`.
  """
  @spec load_for_draw(String.t()) ::
          [%{uuid: String.t(), weight: pos_integer()}]
  def load_for_draw(draw_id) do
    Entry
    |> Ash.Query.filter(draw_id == ^draw_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn e ->
      %{uuid: e.id, weight: e.weight}
    end)
  end
end
