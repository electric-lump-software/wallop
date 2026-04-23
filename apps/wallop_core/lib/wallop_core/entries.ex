defmodule WallopCore.Entries do
  @moduledoc """
  Shared utilities for working with draw entries.
  """

  require Ash.Query

  alias WallopCore.Resources.Entry

  @doc """
  Load all entries for a draw from the entries table as atom-keyed maps
  shaped for `WallopCore.Protocol.entry_hash/1` and `FairPick.draw/3`.

  Returns `[%{uuid, weight}]` in deterministic order —
  `(inserted_at ASC, id ASC)`. Postgres does not guarantee row order
  without an explicit `ORDER BY`; the tiebreaker on `id` gives a total
  order even for rows inserted in the same microsecond. `entry_hash`
  and `FairPick` each sort internally by uuid before any commitment,
  so this sort does not affect canonical bytes — but it does stabilise
  the iteration order seen by display / PDF / webhook paths.

  Callers that need FairPick's `[%{id, weight}]` shape should map
  `%{id: e.uuid, weight: e.weight}`.
  """
  @spec load_for_draw(String.t()) ::
          [%{uuid: String.t(), weight: pos_integer()}]
  def load_for_draw(draw_id) do
    Entry
    |> Ash.Query.filter(draw_id == ^draw_id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn e ->
      %{uuid: e.id, weight: e.weight}
    end)
  end
end
