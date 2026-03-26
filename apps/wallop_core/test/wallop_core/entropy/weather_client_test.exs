defmodule WallopCore.Entropy.WeatherClientTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.WeatherClient

  @latitude 51.5074
  @longitude -0.1278

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

  describe "fetch/2" do
    test "returns raw mslp integer as string, observation_time, and raw response" do
      assert {:ok, result} = WeatherClient.fetch(@latitude, @longitude)

      assert result.value == "101410"
      assert result.observation_time == ~U[2025-01-15 13:00:00Z]
      assert is_binary(result.raw)

      # raw is valid JSON
      assert {:ok, _decoded} = Jason.decode(result.raw)
    end

    test "returns the latest observation time series entry" do
      Req.Test.stub(WeatherClient, fn conn ->
        body = %{
          "type" => "FeatureCollection",
          "features" => [
            %{
              "properties" => %{
                "timeSeries" => [
                  %{"time" => "2025-06-01T09:00Z", "mslp" => 100_830},
                  %{"time" => "2025-06-01T10:00Z", "mslp" => 100_970}
                ]
              }
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:ok, result} = WeatherClient.fetch(@latitude, @longitude)
      assert result.value == "100970"
      assert result.observation_time == ~U[2025-06-01 10:00:00Z]
    end

    test "returns error when no readings have mslp" do
      Req.Test.stub(WeatherClient, fn conn ->
        body = %{
          "type" => "FeatureCollection",
          "features" => [
            %{
              "properties" => %{
                "timeSeries" => [
                  %{"time" => "2025-01-15T08:00Z"}
                ]
              }
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :no_readings_available} = WeatherClient.fetch(@latitude, @longitude)
    end

    test "returns error for non-200 response" do
      Req.Test.stub(WeatherClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "internal error")
      end)

      assert {:error, {:unexpected_status, 500}} = WeatherClient.fetch(@latitude, @longitude)
    end

    test "returns error for invalid response structure" do
      Req.Test.stub(WeatherClient, fn conn ->
        body = %{"unexpected" => "format"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :invalid_response} = WeatherClient.fetch(@latitude, @longitude)
    end
  end

  # Default stub handler — returns a valid Met Office response with mslp in Pascals.
  # Latest entry is 13:00 with mslp 101410 Pa (1014.10 hPa).
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
              %{"time" => "2025-01-15T11:00Z", "mslp" => 101_280},
              %{"time" => "2025-01-15T12:00Z", "mslp" => 101_340},
              %{"time" => "2025-01-15T13:00Z", "mslp" => 101_410}
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
