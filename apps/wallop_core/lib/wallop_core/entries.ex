defmodule WallopCore.Entries do
  @moduledoc """
  Shared utilities for working with draw entries.

  Entries arrive from JSON as string-keyed maps and need conversion to
  atom-keyed maps for the protocol and algorithm layers.
  """

  import Ecto.Query

  @doc """
  Convert a list of entries from string-keyed or atom-keyed maps to atom-keyed maps.

  Accepts either `%{"id" => ..., "weight" => ...}` or `%{id: ..., weight: ...}`.
  """
  @spec to_atom_keys([map()]) :: [%{id: String.t(), weight: pos_integer()}]
  def to_atom_keys(entries) when is_list(entries) do
    Enum.map(entries, fn
      %{id: _, weight: _} = entry -> entry
      %{"id" => id, "weight" => weight} -> %{id: id, weight: weight}
    end)
  end

  @doc """
  Load all entries for a draw from the entries table as atom-keyed maps.
  """
  @spec load_for_draw(String.t()) :: [%{id: String.t(), weight: pos_integer()}]
  def load_for_draw(draw_id) do
    from(e in "entries",
      where: e.draw_id == type(^draw_id, :binary_id),
      select: %{id: e.entry_id, weight: e.weight}
    )
    |> WallopCore.Repo.all()
  end
end
