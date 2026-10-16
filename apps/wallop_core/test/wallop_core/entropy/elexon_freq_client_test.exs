defmodule WallopCore.Entropy.ElexonFreqClientTest do
  use ExUnit.Case, async: false

  alias WallopCore.Entropy.ElexonFreqClient

  @fixture Path.expand("../../fixtures/elexon/freq-2026-10-14T19-54-15.json", __DIR__)
  @vectors Path.expand("../../../../../spec/vectors/freq-window-v1.json", __DIR__)
  @t ~U[2026-10-14 19:54:15.000000Z]
  @value "50018;50012;49983;49980;49953;49912;49883;49887"

  setup do
    Application.put_env(:wallop_core, ElexonFreqClient, plug: {Req.Test, ElexonFreqClient})
    on_exit(fn -> Application.delete_env(:wallop_core, ElexonFreqClient) end)
  end

  defp serve(status, body, headers \\ []) do
    test_pid = self()

    Req.Test.stub(ElexonFreqClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn, conn.query_params, conn.req_headers})

      headers
      |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  test "the real response gives the window's value, in time order, with the raw bytes" do
    body = File.read!(@fixture)
    serve(200, body)

    assert {:ok, %{value: @value, raw: ^body, freq_start: @t}} = ElexonFreqClient.fetch_window(@t)

    assert_received {:request, conn, params, headers}
    assert conn.scheme == :https
    assert conn.host == "data.elexon.co.uk"
    assert conn.request_path == "/bmrs/api/v1/datasets/FREQ"

    # Exactly the window's 105 s, so a request never spans more than a day.
    assert params == %{
             "measurementDateTimeFrom" => "2026-10-14T19:54:15Z",
             "measurementDateTimeTo" => "2026-10-14T19:56:00Z",
             "format" => "json"
           }

    assert List.keyfind(headers, "accept", 0) == {"accept", "application/json"}
    refute List.keymember?(headers, "accept-encoding", 0)
    refute List.keymember?(headers, "authorization", 0)
    refute List.keymember?(headers, "apikey", 0)
  end

  test "every shared window vector gives the same result through the client" do
    vectors = @vectors |> File.read!() |> Jason.decode!()
    {:ok, start, 0} = DateTime.from_iso8601(vectors["freq_start"])
    start = %{start | microsecond: {0, 6}}

    for %{"name" => name, "body" => body} = vector <- vectors["cases"] do
      serve(200, body)

      expected =
        case vector do
          %{"value" => value} ->
            {:ok, %{value: value, raw: body, freq_start: start}}

          %{"invalid" => %{"reason" => "stuck"}} ->
            {:error, :stuck}

          %{"invalid" => %{"reason" => "duplicate_key"}} ->
            {:error, :duplicate_key}

          %{"invalid" => %{"reason" => reason, "at" => at}} ->
            {:error, {String.to_existing_atom(reason), at}}
        end

      assert ElexonFreqClient.fetch_window(start) == expected, name
    end
  end

  test "only a window start: UTC, whole seconds, on the 15 s grid" do
    Req.Test.stub(ElexonFreqClient, fn _conn -> flunk("sent a request for a bad window") end)

    for bad <- [
          ~U[2026-10-14 19:54:16.000000Z],
          ~U[2026-10-14 19:54:15.000001Z],
          ~U[2026-10-14 19:54:00.500000Z],
          %{~U[2026-10-14 19:54:15.000000Z] | time_zone: "Europe/London", zone_abbr: "BST"}
        ] do
      assert ElexonFreqClient.fetch_window(bad) == {:error, :not_a_window_start}
    end
  end

  test "https only, with no query or userinfo in the base URL" do
    Req.Test.stub(ElexonFreqClient, fn _conn -> flunk("sent a request to a bad base URL") end)

    for base <- [
          "http://data.elexon.co.uk/bmrs/api/v1/datasets/FREQ",
          "https://data.elexon.co.uk/bmrs/api/v1/datasets/FREQ?format=xml",
          "https://data.elexon.co.uk/bmrs/api/v1/datasets/FREQ?",
          "https://user:pw@data.elexon.co.uk/bmrs/api/v1/datasets/FREQ",
          "https:///FREQ",
          "//data.elexon.co.uk/bmrs/api/v1/datasets/FREQ",
          :not_a_url
        ] do
      Application.put_env(:wallop_core, ElexonFreqClient,
        base_url: base,
        plug: {Req.Test, ElexonFreqClient}
      )

      assert ElexonFreqClient.fetch_window(@t) == {:error, :insecure_url}, inspect(base)
    end
  end

  test "a redirect is an error and is never followed" do
    Req.Test.stub(ElexonFreqClient, fn conn ->
      if conn.host == "data.elexon.co.uk" do
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/FREQ")
        |> Plug.Conn.send_resp(302, "")
      else
        flunk("followed a redirect to #{conn.host}")
      end
    end)

    assert ElexonFreqClient.fetch_window(@t) == {:error, {:unexpected_status, 302}}
  end

  test "a body over the cap is refused, never parsed" do
    serve(200, ~s({"data":[]}) <> String.duplicate(" ", ElexonFreqClient.max_body_bytes()))
    assert ElexonFreqClient.fetch_window(@t) == {:error, :body_too_large}
  end

  test "a body exactly at the cap is read" do
    body = File.read!(@fixture)
    padded = body <> String.duplicate(" ", ElexonFreqClient.max_body_bytes() - byte_size(body))
    serve(200, padded)

    assert {:ok, %{value: @value, raw: ^padded}} = ElexonFreqClient.fetch_window(@t)
  end

  test "a body nested too deeply is refused" do
    serve(200, ~s({"data":) <> String.duplicate("[", 8) <> String.duplicate("]", 8) <> "}")
    assert ElexonFreqClient.fetch_window(@t) == {:error, :too_deep}
  end

  test "HTTP errors, the wrong shape, bad JSON and an invalid window" do
    serve(503, "{}")
    assert ElexonFreqClient.fetch_window(@t) == {:error, {:unexpected_status, 503}}

    for body <- [~s({"data": 5}), "[]", ~s({"other":[]}), ~s({"data": null})] do
      serve(200, body)
      assert ElexonFreqClient.fetch_window(@t) == {:error, :invalid_response}, body
    end

    serve(200, "{not json")
    assert ElexonFreqClient.fetch_window(@t) == {:error, :invalid_json}

    serve(200, String.replace(File.read!(@fixture), "49.983", "0"))
    assert ElexonFreqClient.fetch_window(@t) == {:error, {:zero, "2026-10-14T19:54:45Z"}}
  end

  test "a transport error passes on only an atom reason" do
    Req.Test.stub(ElexonFreqClient, &Req.Test.transport_error(&1, :timeout))
    assert ElexonFreqClient.fetch_window(@t) == {:error, {:transport, :timeout}}

    mint = %Mint.TransportError{reason: :econnrefused}

    Req.Test.stub(ElexonFreqClient, fn conn -> put_in(conn.private[:req_test_exception], mint) end)

    assert ElexonFreqClient.fetch_window(@t) == {:error, {:transport, :econnrefused}}

    Req.Test.stub(ElexonFreqClient, &Req.Test.transport_error(&1, {:bad_alpn_protocol, "h3"}))
    assert ElexonFreqClient.fetch_window(@t) == {:error, {:transport, :http_error}}

    leaky = %Mint.HTTPError{
      reason: {:invalid_header_value, "x-request", "detail\n"},
      module: Mint.HTTP1
    }

    Req.Test.stub(ElexonFreqClient, fn conn ->
      put_in(conn.private[:req_test_exception], leaky)
    end)

    assert ElexonFreqClient.fetch_window(@t) == {:error, {:transport, :http_error}}
  end

  test "config may set only the plug and the two timeouts" do
    Application.put_env(:wallop_core, ElexonFreqClient,
      plug: {Req.Test, ElexonFreqClient},
      req_options: [
        receive_timeout: 1_234,
        connect_options: [timeout: 567, transport_opts: [verify: :verify_none]],
        redirect: true,
        retry: :transient,
        max_retries: 5,
        compressed: true,
        decode_body: true,
        headers: [{"x-extra", "1"}]
      ]
    )

    assert Enum.sort(ElexonFreqClient.request_options()) ==
             Enum.sort(
               connect_options: [timeout: 567],
               receive_timeout: 1_234,
               redirect: false,
               retry: false,
               compressed: false,
               decode_body: false,
               plug: {Req.Test, ElexonFreqClient}
             )

    counter = :counters.new(1, [])

    Req.Test.stub(ElexonFreqClient, fn conn ->
      :counters.add(counter, 1, 1)
      assert [] = Plug.Conn.get_req_header(conn, "x-extra")
      Plug.Conn.send_resp(conn, 503, "{}")
    end)

    assert ElexonFreqClient.fetch_window(@t) == {:error, {:unexpected_status, 503}}
    assert :counters.get(counter, 1) == 1
  end
end
