defmodule WallopCore.Frequency.FreqGrammar do
  @moduledoc """
  `freq_value` for grid-frequency draws: the 8 Elexon FREQ readings of a
  window, in time order, each as whole mHz with exactly 5 digits, joined by
  `;` (for example `"50018;50012;49983;49980;49953;49912;49883;49887"`).

  Each reading is read from its own JSON number text: digits, then at most
  3 decimal places, padded with zeros (JSON drops trailing zeros, so
  `49.98` is 49980). Never through a float. An exponent, a sign, a leading
  zero, a quoted number or null makes the reading invalid.

  A window is invalid if any of its 8 readings is missing, exactly 0,
  outside [47000, 52999] mHz, or appears more than once, or if it holds a
  run of `stuck_run/0` or more identical readings in a row (a stuck feed).

  Frozen by the `drand-quicknet+elexon-freq-v1` tag, and identical to the
  verifier's rules.
  """

  alias WallopCore.Frequency.Schedule

  @bounds 47_000..52_999
  @stuck_run 6
  @readings Schedule.readings()
  @reading_text ~r/\A(0|[1-9][0-9]{0,5})(?:\.([0-9]{1,3}))?\z/
  @value_regex Regex.compile!("\\A[0-9]{5}(?:;[0-9]{5}){#{@readings - 1}}\\z")

  @type window_error ::
          {:missing | :duplicate | :zero | :invalid | :out_of_bounds, String.t()} | :stuck

  @spec bounds() :: Range.t()
  def bounds, do: @bounds

  @spec stuck_run() :: pos_integer()
  def stuck_run, do: @stuck_run

  @doc "Decodes JSON keeping every number as `{:number, text}`."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  defdelegate decode(body), to: WallopCore.Weather.LandObsGrammar

  @doc "One reading's JSON number as whole mHz, or why it is not a valid reading."
  @spec reading_mhz(term()) :: {:ok, pos_integer()} | {:error, :zero | :invalid | :out_of_bounds}
  def reading_mhz({:number, text}) when is_binary(text) do
    case Regex.run(@reading_text, text, capture: :all_but_first) do
      [int, frac] -> to_mhz(int, frac)
      [int] -> to_mhz(int, "")
      nil -> {:error, :invalid}
    end
  end

  def reading_mhz(_), do: {:error, :invalid}

  defp to_mhz(int, frac) do
    mhz = String.to_integer(int) * 1000 + String.to_integer(String.pad_trailing(frac, 3, "0"))

    cond do
      mhz == 0 -> {:error, :zero}
      mhz in @bounds -> {:ok, mhz}
      true -> {:error, :out_of_bounds}
    end
  end

  @doc "True when `value` is a `freq_value`: grammar, bounds and no stuck run."
  @spec valid_value?(term()) :: boolean()
  def valid_value?(value) when is_binary(value) do
    if Regex.match?(@value_regex, value) do
      readings = value |> String.split(";") |> Enum.map(&String.to_integer/1)
      Enum.all?(readings, &(&1 in @bounds)) and not stuck?(readings)
    else
      false
    end
  end

  def valid_value?(_), do: false

  @doc """
  The `freq_value` of the window starting at `freq_start`, from decoded
  Elexon rows (`%{"measurementTime" => "YYYY-MM-DDTHH:MM:SSZ", "frequency" =>
  {:number, text}}`), or the first reason the window is invalid.

  The row rule:

    * a row that is not a JSON object is ignored;
    * an object row belongs to a reading time when its `measurementTime` is
      exactly that time's text, `YYYY-MM-DDTHH:MM:SSZ` (so
      `...T19:55:00.000Z` matches nothing); object rows at no reading time
      are ignored;
    * every object row that matches counts, whatever else it holds. One
      matching row gives the reading, and a missing, null, quoted or
      malformed `frequency` makes the window invalid. Two or more
      matching rows make it `:duplicate`, even if their values are equal or
      one of them has no `frequency`.

  Reading times are checked in time order and the first failure is
  returned; a stuck run is checked once all 8 readings are good. This is
  the canonical rule: the verifier and `spec/vectors/freq-window-v1.json`
  follow it.
  """
  @spec window_from_rows(list(), DateTime.t()) :: {:ok, String.t()} | {:error, window_error()}
  def window_from_rows(rows, %DateTime{} = freq_start) when is_list(rows) do
    rows = Enum.filter(rows, &is_map/1)

    freq_start
    |> Schedule.reading_times()
    |> Enum.reduce_while({:ok, []}, fn t, {:ok, acc} ->
      stamp = Calendar.strftime(t, "%Y-%m-%dT%H:%M:%SZ")

      case Enum.filter(rows, &(&1["measurementTime"] == stamp)) do
        [] -> {:halt, {:error, {:missing, stamp}}}
        [row] -> reading_in(row, stamp, acc)
        _ -> {:halt, {:error, {:duplicate, stamp}}}
      end
    end)
    |> case do
      {:ok, reversed} -> finish(Enum.reverse(reversed))
      error -> error
    end
  end

  defp reading_in(row, stamp, acc) do
    case reading_mhz(row["frequency"]) do
      {:ok, mhz} -> {:cont, {:ok, [mhz | acc]}}
      {:error, reason} -> {:halt, {:error, {reason, stamp}}}
    end
  end

  defp finish(readings) do
    if stuck?(readings),
      do: {:error, :stuck},
      else: {:ok, Enum.map_join(readings, ";", &Integer.to_string/1)}
  end

  defp stuck?(readings),
    do: readings |> Enum.chunk_by(& &1) |> Enum.map(&length/1) |> Enum.max() >= @stuck_run
end
