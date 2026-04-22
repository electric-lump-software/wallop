defmodule WallopCore.Proof do
  @moduledoc """
  Proof verification and public-facing entry lookup.

  Entries are identified publicly by their wallop-assigned UUID (the Ash PK
  `id`). `operator_ref` is NEVER exposed by anything in this module.
  """

  require Ash.Query

  alias WallopCore.Resources.Entry

  @doc """
  Re-verify a completed draw by re-running the algorithm.

  Returns `{:ok, :verified}` if results match, `{:error, :mismatch}` if not.
  Only works on completed draws with a seed.
  """
  @spec verify(map()) :: {:ok, :verified} | {:error, :mismatch}
  def verify(draw) do
    entries = WallopCore.Entries.load_for_draw(draw.id)
    seed_bytes = Base.decode16!(draw.seed, case: :mixed)
    fair_pick_entries = Enum.map(entries, &%{id: &1.uuid, weight: &1.weight})
    computed = FairPick.draw(fair_pick_entries, seed_bytes, draw.winner_count)

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
  Public self-check: is a given UUID in the winner list of this draw?

  Returns a flat boolean. Pre-launch decision (2026-04-22): wallop's public
  endpoint exposes only what is already public on the proof page. The
  operator gates any richer state (entered/didn't-win/position) via their
  own `metadata.check_url` page.

  Accepts any string input. Invalid UUIDs, UUIDs that entered but didn't
  win, and UUIDs that never entered all return `{:ok, %{winner: false}}` —
  byte-identical response.
  """
  @spec winner?(map(), String.t()) :: {:ok, %{winner: boolean()}}
  def winner?(draw, uuid) when is_binary(uuid) do
    winner_uuids =
      (draw.results || [])
      |> Enum.map(& &1["entry_id"])
      |> MapSet.new()

    {:ok, %{winner: MapSet.member?(winner_uuids, uuid)}}
  end

  @doc """
  DEPRECATED — kept temporarily while PAM-1011 lands.

  Old three-state lookup. Use `winner?/2` for new code. This function will
  be removed in the self-check flat-boolean card.
  """
  @spec check_entry(map(), String.t()) ::
          {:ok, %{found: boolean(), winner: boolean(), position: non_neg_integer() | nil}}
  def check_entry(draw, uuid) when is_binary(uuid) do
    in_entries? =
      Entry
      |> Ash.Query.filter(draw_id == ^draw.id and id == ^uuid)
      |> Ash.exists?(authorize?: false)

    if in_entries? do
      winner =
        Enum.find(draw.results || [], fn r ->
          r["entry_id"] == uuid
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
