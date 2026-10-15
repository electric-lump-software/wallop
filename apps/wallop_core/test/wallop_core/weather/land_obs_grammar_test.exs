defmodule WallopCore.Weather.LandObsGrammarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias WallopCore.Weather.LandObsGrammar, as: G

  @row_1900 ~s({"temperature": 14.11, "visibility": 24320.0, "weather_code": 8, "datetime": "2026-10-14T19:00:00Z", "humidity": 85, "mslp": 1025, "wind_gust": 6.9, "wind_speed": 4.0, "pressure_tendency": "F", "wind_direction": "S"})
  @row_1200 ~s({"datetime": "2026-10-15T12:00:00Z", "humidity": 76, "mslp": 1020, "pressure_tendency": "R", "temperature": 19.59, "visibility": 60230.0, "weather_code": 8, "wind_direction": "SW", "wind_gust": 9.9, "wind_speed": 5.5})

  defp row(json) do
    {:ok, r} = G.decode(json)
    r
  end

  defp value_of(fields) do
    base = %{
      "temperature" => "1.0",
      "mslp" => "1000",
      "humidity" => "50",
      "visibility" => "1000"
    }

    json =
      base |> Map.merge(fields) |> Enum.map_join(", ", fn {k, v} -> ~s("#{k}": #{v}) end)

    G.canonical_value(row("{" <> json <> "}"))
  end

  test "numbers keep their JSON text" do
    assert %{
             "temperature" => {:number, "19.59"},
             "visibility" => {:number, "60230.0"},
             "wind_direction" => "SW"
           } = row(@row_1200)
  end

  test "canonicalises real rows" do
    assert {:ok, "141;1025;85;2432"} = G.canonical_value(row(@row_1900))
    assert {:ok, "196;1020;76;6023"} = G.canonical_value(row(@row_1200))
  end

  test "temperature rounds half away from zero from the decimal text" do
    for {t, want} <- [
          {"19.55", "196"},
          {"19.549", "195"},
          {"-0.05", "-1"},
          {"-0.04", "0"},
          {"-0.0", "0"},
          {"0.0", "0"},
          {"-12.35", "-124"},
          {"7", "70"}
        ] do
      assert {:ok, ^want <> ";1000;50;100"} = value_of(%{"temperature" => t})
    end
  end

  test "visibility must be whole metres, then rounds to decametres" do
    assert {:ok, "10;1000;50;3"} = value_of(%{"visibility" => "25"})
    assert {:ok, "10;1000;50;2"} = value_of(%{"visibility" => "24"})
    assert {:ok, "10;1000;50;4114"} = value_of(%{"visibility" => "41140.0"})
    assert {:ok, "10;1000;50;4115"} = value_of(%{"visibility" => "41145"})
    assert {:error, {:not_integral, "visibility"}} = value_of(%{"visibility" => "41140.5"})
    assert {:error, {:not_integral, "visibility"}} = value_of(%{"visibility" => "41140.04"})
    assert {:error, {:invalid, "visibility"}} = value_of(%{"visibility" => "4.114e4"})
  end

  test "mslp and humidity must be whole numbers; trailing zero decimals are fine" do
    assert {:ok, "10;1021;50;100"} = value_of(%{"mslp" => "1021.0"})
    assert {:error, {:not_integral, "mslp"}} = value_of(%{"mslp" => "1020.4"})
    assert {:error, {:not_integral, "humidity"}} = value_of(%{"humidity" => "76.5"})
  end

  test "any missing, null or non-numeric required field makes the row invalid" do
    for key <- ~w(temperature mslp humidity visibility) do
      assert {:error, {:missing, ^key}} = G.canonical_value(Map.delete(row(@row_1200), key))
      assert {:error, {:missing, ^key}} = value_of(%{key => "null"})
      assert {:error, {:invalid, ^key}} = value_of(%{key => ~s("20")})
      assert {:error, {:invalid, ^key}} = value_of(%{key => "true"})
      assert {:error, {:invalid, ^key}} = value_of(%{key => "[1]"})
      assert {:error, {:invalid, ^key}} = value_of(%{key => ~s({"v": 1})})
    end
  end

  test "a row that is not an object is not an observation" do
    assert {:error, :not_an_object} = G.canonical_value([1, 2])
    assert {:error, :not_an_object} = G.canonical_value(nil)
  end

  test "an exponent is rejected per field: in a required field it invalidates the row, elsewhere it is ignored" do
    assert {:error, {:invalid, "temperature"}} = value_of(%{"temperature" => "1.959e1"})
    assert {:error, {:invalid, "mslp"}} = value_of(%{"mslp" => "1.02E3"})
    assert {:ok, "10;1000;50;100"} = value_of(%{"wind_speed" => "4e0"})
    assert {:ok, "10;1000;50;100"} = value_of(%{"wind_speed" => "1e400"})
  end

  test "bounds, after scaling: t [-900, 600], mslp [850, 1100], rh [0, 100], vis [0, 10000]" do
    assert {:ok, "600;1000;50;100"} = value_of(%{"temperature" => "60.0"})
    assert {:ok, "600;1000;50;100"} = value_of(%{"temperature" => "60.04"})
    assert {:ok, "-900;1000;50;100"} = value_of(%{"temperature" => "-90.0"})
    assert {:ok, "-900;1000;50;100"} = value_of(%{"temperature" => "-90.04"})
    assert {:error, {:out_of_bounds, "temperature"}} = value_of(%{"temperature" => "60.05"})
    assert {:error, {:out_of_bounds, "temperature"}} = value_of(%{"temperature" => "60.1"})
    assert {:error, {:out_of_bounds, "temperature"}} = value_of(%{"temperature" => "-90.05"})
    assert {:error, {:out_of_bounds, "temperature"}} = value_of(%{"temperature" => "-90.1"})
    assert {:ok, _} = value_of(%{"mslp" => "850"})
    assert {:ok, _} = value_of(%{"mslp" => "1100"})
    assert {:error, {:out_of_bounds, "mslp"}} = value_of(%{"mslp" => "849"})
    assert {:error, {:out_of_bounds, "mslp"}} = value_of(%{"mslp" => "1101"})
    assert {:ok, "10;1000;0;100"} = value_of(%{"humidity" => "0"})
    assert {:error, {:out_of_bounds, "humidity"}} = value_of(%{"humidity" => "101"})
    assert {:error, {:out_of_bounds, "humidity"}} = value_of(%{"humidity" => "-1"})
    assert {:ok, "10;1000;50;0"} = value_of(%{"visibility" => "0"})
    assert {:ok, "10;1000;50;10000"} = value_of(%{"visibility" => "100000"})
    assert {:ok, "10;1000;50;10000"} = value_of(%{"visibility" => "100004"})
    assert {:error, {:out_of_bounds, "visibility"}} = value_of(%{"visibility" => "100005"})
    assert {:error, {:out_of_bounds, "visibility"}} = value_of(%{"visibility" => "100010"})
    assert {:error, {:out_of_bounds, "visibility"}} = value_of(%{"visibility" => "-10"})
  end

  test "scale_decimal mirrors the verifier" do
    assert {:ok, 196} = G.scale_decimal("19.59", 1, false)
    assert {:ok, 196} = G.scale_decimal("19.55", 1, false)
    assert {:ok, 195} = G.scale_decimal("19.549", 1, false)
    assert {:ok, 184} = G.scale_decimal("18.38", 1, false)
    assert {:ok, 70} = G.scale_decimal("7", 1, false)
    assert {:ok, -1} = G.scale_decimal("-0.05", 1, false)
    assert {:ok, 0} = G.scale_decimal("-0.04", 1, false)
    assert {:ok, 0} = G.scale_decimal("-0.0", 1, false)
    assert {:ok, -35} = G.scale_decimal("-3.45", 1, false)
    assert {:ok, -124} = G.scale_decimal("-12.35", 1, false)
    assert {:ok, 4114} = G.scale_decimal("41140.0", -1, false)
    assert {:ok, 1021} = G.scale_decimal("1021", 0, true)
    assert {:ok, 1021} = G.scale_decimal("1021.0", 0, true)

    for bad <-
          ["1e2", "1.0E2", "NaN", "", "-", ".5", "5.", ~s("18.3"), "null", "+1"] ++
            ["--1", "1.2.3", " 1", "1 ", "1\n", "١"] do
      assert {:error, :not_plain_decimal} = G.scale_decimal(bad, 0, true), inspect(bad)
    end

    assert {:error, :not_whole} = G.scale_decimal("1021.5", 0, true)
    assert {:error, :too_many_digits} = G.scale_decimal("1234567890123456", 0, true)
    assert {:error, :too_many_digits} = G.scale_decimal("12345678.90123456", 0, false)
    assert {:ok, 123_456_789_012_345} = G.scale_decimal("123456789012345", 0, true)
  end

  property "scale_decimal rounds like Decimal half_up (away from zero)" do
    check all(
            neg <- boolean(),
            int <- integer(0..99_999),
            frac <- string(?0..?9, min_length: 0, max_length: 6),
            shift <- integer(-2..2)
          ) do
      text = if(neg, do: "-", else: "") <> Integer.to_string(int)
      text = if frac == "", do: text, else: text <> "." <> frac

      want =
        text
        |> Decimal.new()
        |> Decimal.mult(Decimal.new(1, 1, shift))
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()

      assert {:ok, ^want} = G.scale_decimal(text, shift, false)
    end
  end

  property "every value canonical_value produces satisfies valid_value?" do
    check all(
            t <- integer(-1000..700),
            t_frac <- integer(0..99),
            mslp <- integer(800..1150),
            rh <- integer(-5..110),
            vis <- integer(0..110_000)
          ) do
      json =
        ~s({"temperature": #{t}.#{t_frac}, "mslp": #{mslp}, "humidity": #{rh}, "visibility": #{vis}})

      case G.canonical_value(row(json)) do
        {:ok, value} -> assert G.valid_value?(value), value
        {:error, {:out_of_bounds, _}} -> :ok
      end
    end
  end

  test "NaN and Infinity are not JSON" do
    assert {:error, _} = G.decode(~s({"temperature": NaN}))
    assert {:error, _} = G.decode(~s({"temperature": Infinity}))
    assert {:error, _} = G.decode(~s({"temperature": 1.}))
  end

  test "decode keeps structure, escapes, whitespace and the last duplicate key" do
    body =
      ~s(\n [ {"a" : -0.0 , "b\\"c": "x,\\u00e9]:", "d": [1, {"e": null}, true, false]},\t{} ] )

    assert {:ok,
            [
              %{
                "a" => {:number, "-0.0"},
                "b\"c" => "x,é]:",
                "d" => [{:number, "1"}, %{"e" => nil}, true, false]
              },
              %{}
            ]} = G.decode(body)

    assert {:ok, %{"t" => {:number, "2"}}} = G.decode(~s({"t": 1, "t": 2}))
    assert {:ok, {:number, "5"}} = G.decode("5")
  end

  test "valid_value?/1 is the published grammar with the bounds" do
    for ok <- [
          "196;1020;76;6023",
          "-900;850;0;0",
          "600;1100;100;10000",
          "0;1000;50;0",
          "184;1021;51;4114",
          "-35;998;100;0"
        ],
        do: assert(G.valid_value?(ok), ok)

    for bad <- [
          "-0;1020;76;6023",
          "0196;1020;76;6023",
          "196;1020;76",
          "196;-1020;76;6023",
          "196;1020;76;6023;1",
          " 196;1020;76;6023",
          "196;1020;76;6023 ",
          "196;1020;76;6023\n",
          "601;1020;76;6023",
          "-901;1020;76;6023",
          "196;849;76;6023",
          "196;1101;76;6023",
          "196;1020;101;6023",
          "196;1020;76;10001",
          "",
          ";;;",
          "+184;1021;51;4114",
          "18.4;1021;51;4114",
          "1e2;1021;51;4114",
          "184,1021,51,4114",
          "１８４;1021;51;4114",
          "--1;1021;51;4114",
          "-;1021;51;4114",
          "184;1021;051;4114",
          "00;1021;51;4114",
          "-00;1021;51;4114",
          "184;1021;51;-0",
          "184;;51;4114",
          nil,
          196
        ] do
      refute G.valid_value?(bad), inspect(bad)
    end
  end
end
