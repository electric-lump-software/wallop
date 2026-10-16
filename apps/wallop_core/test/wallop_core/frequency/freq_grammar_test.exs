defmodule WallopCore.Frequency.FreqGrammarTest do
  use ExUnit.Case, async: true
  alias WallopCore.Frequency.FreqGrammar, as: G

  @t ~U[2026-10-14 19:54:15.000000Z]
  # The real Elexon readings for 2026-10-14 19:54:15..19:56:00 UTC.
  @real ~w(50.018 50.012 49.983 49.98 49.953 49.912 49.883 49.887)
  @real_value "50018;50012;49983;49980;49953;49912;49883;49887"

  defp stamp(t), do: Calendar.strftime(t, "%Y-%m-%dT%H:%M:%SZ")

  defp row(t, text),
    do: ~s({"dataset":"FREQ","measurementTime":"#{stamp(t)}","frequency":#{text}})

  defp indexed(texts), do: Enum.with_index(texts, fn text, i -> {i, text} end)

  # Elexon lists rows newest first.
  defp body(readings, extra \\ []) do
    rows =
      readings
      |> Enum.map(fn {i, text} -> row(DateTime.add(@t, 15 * i), text) end)
      |> Enum.reverse()

    ~s({"data":[#{Enum.join(rows ++ extra, ",")}]})
  end

  defp rows(json) do
    {:ok, %{"data" => rows}} = G.decode(json)
    rows
  end

  defp window(readings, extra \\ []), do: G.window_from_rows(rows(body(readings, extra)), @t)

  test "constants" do
    assert G.bounds() == 47_000..52_999
    assert G.stuck_run() == 6
  end

  test "reading_mhz reads the JSON number text exactly, never through a float" do
    for {text, expected} <- [
          {"50.018", {:ok, 50_018}},
          {"49.98", {:ok, 49_980}},
          {"50", {:ok, 50_000}},
          {"50.0", {:ok, 50_000}},
          {"47", {:ok, 47_000}},
          {"52.999", {:ok, 52_999}},
          {"0", {:error, :zero}},
          {"0.000", {:error, :zero}},
          {"46.999", {:error, :out_of_bounds}},
          {"53", {:error, :out_of_bounds}},
          {"49.9871", {:error, :invalid}},
          {"4.9987e1", {:error, :invalid}},
          {"5E1", {:error, :invalid}},
          {"-49.987", {:error, :invalid}},
          {"049.987", {:error, :invalid}},
          {"49.", {:error, :invalid}},
          {".5", {:error, :invalid}}
        ] do
      assert G.reading_mhz({:number, text}) == expected, text
    end

    assert G.reading_mhz("50.018") == {:error, :invalid}
    assert G.reading_mhz(nil) == {:error, :invalid}
  end

  test "valid_value?: 8 five-digit readings in bounds, no stuck run of 6" do
    for v <- [
          @real_value,
          "47000;52999;50000;50001;50000;50001;50000;50001",
          "50000;50000;50000;50000;50000;50011;50012;50013"
        ] do
      assert G.valid_value?(v), v
    end

    for v <- [
          "50018;50012;49983;49980;49953;49912;49883",
          "50018;50012;49983;49980;49953;49912;49883;49887;49887",
          "4998;50012;49983;49980;49953;49912;49883;49887",
          "00000;50012;49983;49980;49953;49912;49883;49887",
          "53000;50012;49983;49980;49953;49912;49883;49887",
          "46999;50012;49983;49980;49953;49912;49883;49887",
          "50000;50000;50000;50000;50000;50000;50012;50013",
          "50011;50012;50000;50000;50000;50000;50000;50000",
          "50000;50000;50000;50000;50000;50000;50000;50000",
          " 50018;50012;49983;49980;49953;49912;49883;49887",
          "50018;50012;49983;49980;49953;49912;49883;49887;",
          "50018,50012,49983,49980,49953,49912,49883,49887",
          nil,
          50_018
        ] do
      refute G.valid_value?(v), inspect(v)
    end
  end

  test "window_from_rows: the real rows, newest first, give the value in time order" do
    assert window(indexed(@real)) == {:ok, @real_value}
  end

  test "rows outside the window, and rows that aren't objects, are ignored" do
    extra = [row(DateTime.add(@t, -15), "50.001"), row(DateTime.add(@t, 120), "50.002")]
    assert window(indexed(@real), extra) == {:ok, @real_value}
    assert G.window_from_rows([42, nil | rows(body(indexed(@real)))], @t) == {:ok, @real_value}
  end

  test "a missing reading, a repeated timestamp, a zero, an exponent or a bad bound invalidates the window" do
    assert window(indexed(@real) |> List.delete_at(3)) ==
             {:error, {:missing, "2026-10-14T19:55:00Z"}}

    duplicate = [row(DateTime.add(@t, 45), "49.98")]
    assert window(indexed(@real), duplicate) == {:error, {:duplicate, "2026-10-14T19:55:00Z"}}

    assert window(indexed(List.replace_at(@real, 2, "0"))) ==
             {:error, {:zero, "2026-10-14T19:54:45Z"}}

    assert window(indexed(List.replace_at(@real, 2, "4.9983e1"))) ==
             {:error, {:invalid, "2026-10-14T19:54:45Z"}}

    assert window(indexed(List.replace_at(@real, 2, ~s("49.983")))) ==
             {:error, {:invalid, "2026-10-14T19:54:45Z"}}

    assert window(indexed(List.replace_at(@real, 2, "null"))) ==
             {:error, {:invalid, "2026-10-14T19:54:45Z"}}

    assert window(indexed(List.replace_at(@real, 2, "53.1"))) ==
             {:error, {:out_of_bounds, "2026-10-14T19:54:45Z"}}
  end

  test "a stuck run of 6 identical readings invalidates the window; 5 does not" do
    six = ~w(50.0 50.0 50.0 50.0 50.0 50.0 50.012 50.013)
    five = ~w(50.0 50.0 50.0 50.0 50.0 50.011 50.012 50.013)
    assert window(indexed(six)) == {:error, :stuck}
    assert window(indexed(five)) == {:ok, "50000;50000;50000;50000;50000;50011;50012;50013"}
  end
end
