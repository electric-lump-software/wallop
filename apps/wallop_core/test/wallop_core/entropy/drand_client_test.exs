defmodule WallopCore.Entropy.DrandClientTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.DrandClient

  @chain_hash DrandClient.quicknet_chain_hash()

  setup do
    Req.Test.stub(DrandClient, &handle_request/1)

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    on_exit(fn ->
      Application.delete_env(:wallop_core, DrandClient)
    end)

    :ok
  end

  describe "quicknet_chain_hash/0" do
    test "returns the known quicknet chain hash" do
      assert DrandClient.quicknet_chain_hash() ==
               "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
    end
  end

  describe "fetch/2" do
    test "returns ok tuple with randomness, signature, round, and response" do
      assert {:ok, result} = DrandClient.fetch(@chain_hash, 1000)

      assert result.randomness == "a" <> String.duplicate("0", 63)
      assert result.signature == "abcdef1234567890"
      assert result.round == 1000
      assert is_binary(result.response)

      # response is valid JSON
      assert {:ok, decoded} = Jason.decode(result.response)
      assert decoded["round"] == 1000
    end

    test "validates round matches expected" do
      Req.Test.stub(DrandClient, fn conn ->
        body = %{
          "randomness" => "a" <> String.duplicate("0", 63),
          "signature" => "abcdef1234567890",
          "round" => 9999
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :invalid_response} = DrandClient.fetch(@chain_hash, 1000)
    end

    test "rejects malformed response missing randomness" do
      Req.Test.stub(DrandClient, fn conn ->
        body = %{
          "signature" => "abcdef1234567890",
          "round" => 1000
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :invalid_response} = DrandClient.fetch(@chain_hash, 1000)
    end

    test "rejects randomness that is not 64 hex chars" do
      Req.Test.stub(DrandClient, fn conn ->
        body = %{
          "randomness" => "tooshort",
          "signature" => "abcdef1234567890",
          "round" => 1000
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      assert {:error, :invalid_response} = DrandClient.fetch(@chain_hash, 1000)
    end

    test "returns {:error, :not_found} for 404" do
      Req.Test.stub(DrandClient, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      assert {:error, :not_found} = DrandClient.fetch(@chain_hash, 999_999_999)
    end

    test "returns error for unexpected status" do
      Req.Test.stub(DrandClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "internal error")
      end)

      assert {:error, {:unexpected_status, 500}} = DrandClient.fetch(@chain_hash, 1000)
    end
  end

  describe "fetch_with_failover/2" do
    test "succeeds on first relay" do
      assert {:ok, result} = DrandClient.fetch_with_failover(@chain_hash, 1000)
      assert result.randomness == "a" <> String.duplicate("0", 63)
      assert result.round == 1000
    end

    test "falls through to next relay on 500" do
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(DrandClient, fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          Plug.Conn.send_resp(conn, 500, "down")
        else
          round = conn.request_path |> String.split("/") |> List.last() |> String.to_integer()

          body = %{
            "randomness" => "a" <> String.duplicate("0", 63),
            "signature" => "abcdef1234567890",
            "round" => round
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))
        end
      end)

      assert {:ok, result} = DrandClient.fetch_with_failover(@chain_hash, 1000)
      assert result.round == 1000
      assert :counters.get(call_count, 1) == 2
    end

    test "does NOT failover on 404 (round not yet available)" do
      Req.Test.stub(DrandClient, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      assert {:error, :not_found} = DrandClient.fetch_with_failover(@chain_hash, 999)
    end

    test "returns error when all relays fail" do
      Req.Test.stub(DrandClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "down")
      end)

      assert {:error, {:all_relays_failed, _}} =
               DrandClient.fetch_with_failover(@chain_hash, 1000)
    end
  end

  describe "current_round/1" do
    test "returns the round number from latest endpoint" do
      assert {:ok, 42_000} = DrandClient.current_round(@chain_hash)
    end

    test "returns error for unexpected status" do
      Req.Test.stub(DrandClient, fn conn ->
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      assert {:error, {:unexpected_status, 503}} = DrandClient.current_round(@chain_hash)
    end
  end

  # Default stub handler
  defp handle_request(conn) do
    cond do
      String.contains?(conn.request_path, "/public/latest") ->
        body = %{"round" => 42_000}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))

      String.contains?(conn.request_path, "/public/") ->
        round = conn.request_path |> String.split("/") |> List.last() |> String.to_integer()

        body = %{
          "randomness" => "a" <> String.duplicate("0", 63),
          "signature" => "abcdef1234567890",
          "round" => round
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))

      true ->
        Plug.Conn.send_resp(conn, 404, "not found")
    end
  end
end
