defmodule WallopCore.Entropy.LandObsClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WallopCore.Entropy.LandObsClient
  alias WallopCore.Weather.LandObsGrammar

  @fixtures Path.expand("../../fixtures/landobs", __DIR__)
  @key "test-obs-key"

  setup do
    Application.put_env(:wallop_core, LandObsClient,
      plug: {Req.Test, LandObsClient},
      req_options: [retry: false]
    )

    previous_key = Application.get_env(:wallop_core, :met_office_obs_api_key)
    Application.put_env(:wallop_core, :met_office_obs_api_key, @key)

    on_exit(fn ->
      Application.delete_env(:wallop_core, LandObsClient)

      if previous_key,
        do: Application.put_env(:wallop_core, :met_office_obs_api_key, previous_key),
        else: Application.delete_env(:wallop_core, :met_office_obs_api_key)
    end)
  end

  defp serve(body, status \\ 200) do
    Req.Test.stub(LandObsClient, fn conn ->
      assert ["test-obs-key"] = Plug.Conn.get_req_header(conn, "apikey")
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
      assert conn.scheme == :https
      assert conn.query_string == ""

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp fixture(file), do: File.read!(Path.join(@fixtures, file))

  defp hour_at(file, index) do
    {:ok, rows} = Jason.decode(fixture(file))
    {:ok, dt, 0} = DateTime.from_iso8601(Enum.at(rows, index)["datetime"])
    dt
  end

  test "returns the canonical value for exactly the requested hour, keeping the raw bytes" do
    body = fixture("gcnfur.json")
    serve(body)
    hour = hour_at("gcnfur.json", 0)

    assert {:ok, %{value: value, raw: ^body, observation_time: ^hour}} =
             LandObsClient.fetch_hour("gcnfur", hour)

    assert LandObsGrammar.valid_value?(value)
    # 9.84 C, 1029 hPa, 92 %, 19190.0 m
    assert value == "98;1029;92;1919"
  end

  test "picks the requested hour, not the first or the latest row (backup station)" do
    body = fixture("gcrem9.json")
    serve(body)
    hour = hour_at("gcrem9.json", 2)

    assert {:ok, %{value: "87;1027;90;2467", raw: ^body, observation_time: ^hour}} =
             LandObsClient.fetch_hour("gcrem9", hour)
  end

  test "an hour not in the response is :missing_hour; a repeated hour is :duplicate_hour" do
    serve(
      ~s([{"datetime": "2026-10-14T18:00:00Z", "temperature": 1.0, "mslp": 1000, "humidity": 50, "visibility": 1000}])
    )

    assert {:error, :missing_hour} = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])

    row =
      ~s({"datetime": "2026-10-14T19:00:00Z", "temperature": 1.0, "mslp": 1000, "humidity": 50, "visibility": 1000})

    serve("[#{row},#{row}]")

    assert {:error, :duplicate_hour} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "an invalid row is an error, not a partial value" do
    serve(
      ~s([{"datetime": "2026-10-14T19:00:00Z", "temperature": null, "mslp": 1000, "humidity": 50, "visibility": 1000}])
    )

    assert {:error, {:missing, "temperature"}} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "a body that is not a JSON array of rows is an error" do
    serve(~s({"rows": []}))

    assert {:error, :invalid_response} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])

    serve("not json")
    assert {:error, :invalid_json} = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "HTTP errors and a missing key" do
    serve("{}", 503)

    assert {:error, {:unexpected_status, 503}} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])

    Application.delete_env(:wallop_core, :met_office_obs_api_key)
    assert {:error, :no_api_key} = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])

    Application.put_env(:wallop_core, :met_office_obs_api_key, "")
    assert {:error, :no_api_key} = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "a redirect is an error and is not followed" do
    Req.Test.stub(LandObsClient, fn conn ->
      if conn.host == "data.hub.api.metoffice.gov.uk" do
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/observation")
        |> Plug.Conn.send_resp(302, "")
      else
        flunk("followed a redirect to #{conn.host}")
      end
    end)

    assert {:error, {:unexpected_status, 302}} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "a body over the size cap is refused" do
    serve(String.duplicate(" ", LandObsClient.max_body_bytes() + 1) <> "[]")

    assert {:error, :body_too_large} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "only https base URLs are used" do
    serve("[]")

    Application.put_env(:wallop_core, LandObsClient,
      plug: {Req.Test, LandObsClient},
      base_url: "http://data.hub.api.metoffice.gov.uk/observation-land/1"
    )

    assert {:error, :insecure_url} = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
  end

  test "only the tag's stations, and only whole UTC hours" do
    serve("[]")
    assert {:error, :unknown_station} = LandObsClient.fetch_hour("../x", ~U[2026-10-14 19:00:00Z])

    assert {:error, :unknown_station} =
             LandObsClient.fetch_hour("gcpvj0", ~U[2026-10-14 19:00:00Z])

    assert {:error, :not_an_hour} = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:01Z])

    assert {:error, :not_an_hour} =
             LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00.000001Z])
  end

  test "the key never appears in an error or a log" do
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log(fn ->
        serve("{}", 401)
        result = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
        refute inspect(result) =~ @key

        Req.Test.stub(LandObsClient, &Req.Test.transport_error(&1, :timeout))
        result = LandObsClient.fetch_hour("gcnfur", ~U[2026-10-14 19:00:00Z])
        assert {:error, _} = result
        refute inspect(result) =~ @key
      end)

    refute log =~ @key
  end
end
