defmodule WallopCore.Proof do
  @moduledoc """
  Proof verification and anonymisation logic for public proof pages.
  """

  require Ash.Query

  alias WallopCore.Resources.Entry

  @mask_char "*"
  @mask_length 6

  @doc """
  Anonymise an entry ID. Shows first character + fixed-width mask.

  ## Examples

      iex> WallopCore.Proof.anonymise_id("ticket-47")
      "t******"

      iex> WallopCore.Proof.anonymise_id("a")
      "a******"
  """
  @spec anonymise_id(String.t()) :: String.t()
  def anonymise_id(id) when is_binary(id) and byte_size(id) > 0 do
    String.first(id) <> String.duplicate(@mask_char, @mask_length)
  end

  @doc "Anonymise all entry_ids in a results list."
  @spec anonymise_results([map()]) :: [map()]
  def anonymise_results(results) when is_list(results) do
    Enum.map(results, fn result ->
      Map.update!(result, "entry_id", &anonymise_id/1)
    end)
  end

  @doc """
  Re-verify a completed draw by re-running the algorithm.

  Returns `{:ok, :verified}` if results match, `{:error, :mismatch}` if not.
  Only works on completed draws with a seed.
  """
  @spec verify(map()) :: {:ok, :verified} | {:error, :mismatch}
  def verify(draw) do
    atom_entries = WallopCore.Entries.load_for_draw(draw.id)
    seed_bytes = Base.decode16!(draw.seed, case: :mixed)
    computed = FairPick.draw(atom_entries, seed_bytes, draw.winner_count)

    computed_json =
      Enum.map(computed, fn %{position: pos, entry_id: id} ->
        %{"position" => pos, "entry_id" => id}
      end)

    if computed_json == draw.results do
      {:ok, :verified}
    else
      {:error, :mismatch}
    end
  end

  @doc """
  Check if an entry ID is in a draw and whether it won.

  Returns:
  - `{:ok, %{found: true, winner: true, position: N}}` for a winning entry
  - `{:ok, %{found: true, winner: false}}` for a non-winning entry
  - `{:ok, %{found: false}}` for an entry not in the draw
  """
  @spec check_entry(map(), String.t()) ::
          {:ok, %{found: boolean(), winner: boolean(), position: non_neg_integer() | nil}}
  def check_entry(draw, entry_id) when is_binary(entry_id) do
    in_entries? =
      Entry
      |> Ash.Query.filter(draw_id == ^draw.id and entry_id == ^entry_id)
      |> Ash.exists?(authorize?: false)

    if in_entries? do
      winner =
        Enum.find(draw.results || [], fn r ->
          r["entry_id"] == entry_id
        end)

      if winner do
        {:ok, %{found: true, winner: true, position: winner["position"]}}
      else
        {:ok, %{found: true, winner: false}}
      end
    else
      {:ok, %{found: false}}
    end
  end
end
