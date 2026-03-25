defmodule WallopCore.Entropy.WeatherClientTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.WeatherClient

  @latitude 51.5074
  @longitude -0.1278
  @observation_time ~U[2025-01-15 12:00:00Z]

  setup do
    Req.Test.stub(WeatherClient, &handle_request/1)

    Application.put_env(:wallop_core, WeatherClient, plug: {Req.Test, WeatherClient})
    Application.put_env(:wallop_core, :met_office_api_key, "test-api-key")

    on_exit(fn ->
      Application.delete_env(:wallop_core, WeatherClient)
      Application.delete_env(:wallop_core, :met_office_api_key)
    end)

    :ok
  end

  describe "normalize_pressure/1 with float input" do
    test "rounds 1013.0 to 1013" do
      assert WeatherClient.normalize_pressure(1013.0) == "1013"
    end

    test "rounds 1013.4 down" do
      assert WeatherClient.normalize_pressure(1013.4) == "1013"
    end

    test "rounds 1013.5 up (half-up)" do
      assert WeatherClient.normalize_pressure(1013.5) == "1014"
    end

    test "rounds 1013.9 up" do
      assert WeatherClient.normalize_pressure(1013.9) == "1014"
    end

    test "rounds 998.0 to 998" do
      assert WeatherClient.normalize_pressure(998.0) == "998"
    end

    test "rounds 1050.25 down" do
      assert WeatherClient.normalize_pressure(1050.25) == "1050"
    end

    test "rounds 1050.75 up" do
      assert WeatherClient.normalize_pressure(1050.75) == "1051"
    end
  end

  describe "normalize_pressure/1 with string input" do
    test "rounds string 1013.4 down" do
      assert WeatherClient.normalize_pressure("1013.4") == "1013"
    end

    test "rounds string 1013.5 up (half-up)" do
      assert WeatherClient.normalize_pressure("1013.5") == "1014"
    end
  end

  describe "normalize_pressure/1 with Decimal input" do
    test "rounds Decimal 1013.5 up (half-up)" do
      assert WeatherClient.normalize_pressure(Decimal.new("1013.5")) == "1014"
    end
  end

  describe "fetch/3" do
    test "returns normalized value and raw response for valid data" do
      assert {:ok, result} = WeatherClient.fetch(@latitude, @longitude, @observation_time)

      assert result.value == "1013"
      assert is_binary(result.raw)

      # raw is valid JSON
      assert {:ok, _decoded} = Jason.decode(result.raw)
    end

    test "returns error when reading not found for target hour" do
      Req.Test.stub(WeatherClient, fn conn ->
        body = %{
          "type" => "FeatureCollection",
          "features" => [
            %{
              "properties" => %{
                "timeSeries" => [
                  %{
                    "time" => "2025-01-15T08:00Z",
                    "mslp" => 1010.2
                  }
                ]
              }
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :reading_not_found} =
               WeatherClient.fetch(@latitude, @longitude, @observation_time)
    end

    test "returns error for non-200 response" do
      Req.Test.stub(WeatherClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "internal error")
      end)

      assert {:error, {:unexpected_status, 500}} =
               WeatherClient.fetch(@latitude, @longitude, @observation_time)
    end

    test "returns error for invalid response structure" do
      Req.Test.stub(WeatherClient, fn conn ->
        body = %{"unexpected" => "format"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :invalid_response} =
               WeatherClient.fetch(@latitude, @longitude, @observation_time)
    end
  end

  # Default stub handler — returns a valid Met Office response with mslp at 12:00
  defp handle_request(conn) do
    body = %{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "geometry" => %{
            "type" => "Point",
            "coordinates" => [@longitude, @latitude]
          },
          "properties" => %{
            "requestPointDistance" => 0.0,
            "modelRunDate" => "2025-01-15T12:00Z",
            "timeSeries" => [
              %{
                "time" => "2025-01-15T11:00Z",
                "mslp" => 1012.8
              },
              %{
                "time" => "2025-01-15T12:00Z",
                "mslp" => 1013.4
              },
              %{
                "time" => "2025-01-15T13:00Z",
                "mslp" => 1014.1
              }
            ]
          }
        }
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
