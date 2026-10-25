defmodule WallopCore.Frequency.Windows do
  @moduledoc """
  Storage and lookups for grid-frequency windows
  (`WallopCore.Resources.FrequencyWindow`): one window per start T, shared
  by every draw of T: grid-frequency draws, and observation-weather draws
  whose reading missed its deadline. What may be stored, and when, is
  decided by the database on its own clock; this module only asks.
  """

  require Ash.Query

  alias WallopCore.Frequency.FreqGrammar
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Repo
  alias WallopCore.Resources.{Draw, FrequencyWindow}

  @doc "The database clock, in UTC: the clock the store's window is checked on."
  @spec db_now() :: DateTime.t()
  defdelegate db_now(), to: WallopCore.DbClock, as: :now

  @doc "The window stored for start T, or nil."
  @spec for_start(DateTime.t()) :: FrequencyWindow.t() | nil
  def for_start(%DateTime{} = freq_start) do
    FrequencyWindow
    |> Ash.Query.filter(freq_start == ^freq_start)
    |> Ash.read_one!(authorize?: false)
  end

  @doc """
  The window stored for a draw's `freq_start`, under either lock schema 6
  tag. nil for any other draw, or one whose T has none. Under the
  observation-weather tag the draw uses it only when there is no reading
  for its hour. Takes the draw or its id.
  """
  @spec for_draw(Draw.t() | String.t()) :: FrequencyWindow.t() | nil
  def for_draw(%Draw{lock_schema_version: "6", freq_start: %DateTime{} = t} = draw) do
    if draw.entropy_composition in [Freq.tag(), LandObs.tag()], do: for_start(t)
  end

  def for_draw(%Draw{}), do: nil

  def for_draw(draw_id) when is_binary(draw_id),
    do: for_draw(Ash.get!(Draw, draw_id, authorize?: false))

  @doc """
  Stores the window for T. Refuses unless `value` is exactly what `raw`
  (the Elexon response body) gives for T, so the stored bytes always prove
  the stored value. The database refuses it unless a draw of T (either
  tag) is waiting, T is in its window on the database clock, nothing is stored
  for T yet, and the transaction commits by F.

  Runs in its own transaction and refuses to run inside a caller's, with
  `{:error, :nested_transaction}`: a store must commit (or fail) on its
  own, at once, and a refusal must not roll back someone else's work.
  """
  @spec store(DateTime.t(), String.t(), binary()) ::
          {:ok, FrequencyWindow.t()}
          | {:error, :nested_transaction | :raw_does_not_give_value | term()}
  def store(%DateTime{} = freq_start, value, raw) when is_binary(value) and is_binary(raw) do
    cond do
      Repo.in_transaction?() ->
        {:error, :nested_transaction}

      raw_value(raw, freq_start) != {:ok, value} ->
        {:error, :raw_does_not_give_value}

      true ->
        FrequencyWindow
        |> Ash.Changeset.for_create(:store, %{freq_start: freq_start, value: value, raw: raw})
        |> Ash.create(authorize?: false)
    end
  rescue
    # A refusal at COMMIT (the fetch-deadline check) surfaces here.
    e in Postgrex.Error -> {:error, e}
  end

  defp raw_value(raw, freq_start) do
    case FreqGrammar.decode(raw) do
      {:ok, %{"data" => rows}} when is_list(rows) ->
        FreqGrammar.window_from_rows(rows, freq_start)

      _ ->
        :error
    end
  end

  @doc """
  The ids of grid-frequency draws of T that are waiting for entropy, while
  nothing is stored for T; [] once it is.
  """
  @spec pending_draw_ids(DateTime.t()) :: [String.t()]
  def pending_draw_ids(%DateTime{} = freq_start) do
    if for_start(freq_start) do
      []
    else
      tag = Freq.tag()

      Draw
      |> Ash.Query.filter(
        lock_schema_version == "6" and entropy_composition == ^tag and
          freq_start == ^freq_start and status in [:awaiting_entropy, :pending_entropy]
      )
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)
    end
  end
end
