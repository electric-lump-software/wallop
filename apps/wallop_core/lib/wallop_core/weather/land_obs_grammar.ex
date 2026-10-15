defmodule WallopCore.Weather.LandObsGrammar do
  @moduledoc """
  `weather_value` for observation-weather draws: `"<t>;<mslp>;<rh>;<vis>"`.

    * t: temperature x 10, rounded half away from zero (19.59 -> 196,
      -0.05 -> -1, -0.04 -> 0);
    * mslp: whole hPa;
    * rh: whole percent;
    * vis: visibility in whole metres, / 10, rounded half away from zero.

  Each number is read from its own JSON text as a plain decimal. An
  exponent, NaN or a quoted number in one of these four fields, a missing or
  null field, a fractional digit where a whole number is required, or a
  value outside the bounds makes the row invalid. Other fields are never
  read. There are no partial values and no substitutions. The bounds, after
  scaling, are t [-900, 600], mslp [850, 1100], rh [0, 100], vis [0, 10000].

  Every part is a decimal integer with no leading zeros, and only t may
  carry a minus sign (never "-0").

  The grammar is frozen by the `drand-quicknet+metoffice-landobs-v1` tag
  and matches the verifier's rules exactly.
  """

  @type field :: String.t()
  @type error_reason ::
          {:missing | :invalid | :not_integral | :out_of_bounds, field()} | :not_an_object

  @bounds %{t: -900..600, mslp: 850..1100, rh: 0..100, vis: 0..10_000}
  @value_regex ~r/\A(0|-?[1-9][0-9]{0,2});(0|[1-9][0-9]{0,3});(0|[1-9][0-9]{0,2});(0|[1-9][0-9]{0,4})\z/
  @plain_decimal ~r/\A(-?)([0-9]+)(?:\.([0-9]+))?\z/
  @token ~r/"(?:[^"\\]|\\.)*"|[\[\]{}:,]|[^\s"\[\]{}:,]+/u
  @max_digits 15

  @doc "The inclusive bounds on each canonical part, after scaling."
  @spec bounds() :: %{t: Range.t(), mslp: Range.t(), rh: Range.t(), vis: Range.t()}
  def bounds, do: @bounds

  @doc "True when `value` is a `weather_value` under the grammar and within the bounds."
  @spec valid_value?(term()) :: boolean()
  def valid_value?(value) when is_binary(value) do
    case Regex.run(@value_regex, value, capture: :all_but_first) do
      [_, _, _, _] = parts ->
        [:t, :mslp, :rh, :vis]
        |> Enum.zip(parts)
        |> Enum.all?(fn {k, v} -> String.to_integer(v) in @bounds[k] end)

      _ ->
        false
    end
  end

  def valid_value?(_), do: false

  @doc """
  Decodes JSON, keeping every number as `{:number, text}`, its exact JSON
  text. Strings, booleans, null, arrays and objects decode as usual.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(body) when is_binary(body) do
    # Decimals, so that a valid number too large for a float (in a field
    # nobody reads) does not reject the whole body.
    with {:ok, _} <- Jason.decode(body, floats: :decimals) do
      {term, []} = @token |> Regex.scan(body) |> List.flatten() |> parse_value()
      {:ok, term}
    end
  end

  @doc """
  The `weather_value` of one decoded Land Observations row, or the first
  reason the row is not a valid observation.
  """
  @spec canonical_value(term()) :: {:ok, String.t()} | {:error, error_reason()}
  def canonical_value(row) when is_map(row) do
    with {:ok, t} <- field(row, "temperature", 1, false),
         {:ok, mslp} <- field(row, "mslp", 0, true),
         {:ok, rh} <- field(row, "humidity", 0, true),
         {:ok, _whole_metres} <- field(row, "visibility", 0, true),
         {:ok, vis} <- field(row, "visibility", -1, false),
         :ok <- in_bounds("temperature", t, @bounds.t),
         :ok <- in_bounds("mslp", mslp, @bounds.mslp),
         :ok <- in_bounds("humidity", rh, @bounds.rh),
         :ok <- in_bounds("visibility", vis, @bounds.vis) do
      {:ok, Enum.map_join([t, mslp, rh, vis], ";", &Integer.to_string/1)}
    end
  end

  def canonical_value(_), do: {:error, :not_an_object}

  @doc """
  The plain decimal `text` times 10^`shift`, rounded half away from zero.
  With `exact?`, any digits rounded away must be zero. Exponents, NaN,
  quotes and any sign other than a leading `-` are rejected, as is text
  with more than #{@max_digits} digits.
  """
  @spec scale_decimal(String.t(), integer(), boolean()) ::
          {:ok, integer()} | {:error, :not_plain_decimal | :too_many_digits | :not_whole}
  def scale_decimal(text, shift, exact?) when is_binary(text) do
    case Regex.run(@plain_decimal, text, capture: :all_but_first) do
      [sign, int, frac] -> scale(sign, int, frac, shift, exact?)
      [sign, int] -> scale(sign, int, "", shift, exact?)
      _ -> {:error, :not_plain_decimal}
    end
  end

  defp scale(_sign, int, frac, _shift, _exact?)
       when byte_size(int) + byte_size(frac) > @max_digits,
       do: {:error, :too_many_digits}

  defp scale(sign, int, frac, shift, exact?) do
    n = String.to_integer(int <> frac)

    with {:ok, m} <- magnitude(n, shift - byte_size(frac), exact?) do
      {:ok, if(sign == "-", do: -m, else: m)}
    end
  end

  defp magnitude(n, exp, _exact?) when exp >= 0, do: {:ok, n * Integer.pow(10, exp)}

  defp magnitude(n, exp, exact?) do
    d = Integer.pow(10, -exp)
    q = div(n, d)
    r = rem(n, d)

    cond do
      exact? and r != 0 -> {:error, :not_whole}
      r * 2 >= d -> {:ok, q + 1}
      true -> {:ok, q}
    end
  end

  defp field(row, key, shift, exact?) do
    case Map.get(row, key) do
      nil -> {:error, {:missing, key}}
      {:number, text} -> number(text, key, shift, exact?)
      _ -> {:error, {:invalid, key}}
    end
  end

  defp number(text, key, shift, exact?) do
    case scale_decimal(text, shift, exact?) do
      {:ok, n} -> {:ok, n}
      {:error, :not_whole} -> {:error, {:not_integral, key}}
      {:error, _} -> {:error, {:invalid, key}}
    end
  end

  defp in_bounds(key, n, range),
    do: if(n in range, do: :ok, else: {:error, {:out_of_bounds, key}})

  # A tiny recursive-descent reader over tokens of JSON that Jason has
  # already validated. It differs from Jason only in keeping number text.
  defp parse_value(["{" | rest]), do: parse_object(rest, %{})
  defp parse_value(["[" | rest]), do: parse_array(rest, [])
  defp parse_value([~s(") <> _ = s | rest]), do: {Jason.decode!(s), rest}
  defp parse_value(["null" | rest]), do: {nil, rest}
  defp parse_value(["true" | rest]), do: {true, rest}
  defp parse_value(["false" | rest]), do: {false, rest}
  defp parse_value([number | rest]), do: {{:number, number}, rest}

  defp parse_object(["}" | rest], acc), do: {acc, rest}
  defp parse_object(["," | rest], acc), do: parse_object(rest, acc)

  defp parse_object([key, ":" | rest], acc) do
    {value, rest} = parse_value(rest)
    parse_object(rest, Map.put(acc, Jason.decode!(key), value))
  end

  defp parse_array(["]" | rest], acc), do: {Enum.reverse(acc), rest}
  defp parse_array(["," | rest], acc), do: parse_array(rest, acc)

  defp parse_array(tokens, acc) do
    {value, rest} = parse_value(tokens)
    parse_array(rest, [value | acc])
  end
end
