defmodule WallopWeb.Plugs.KeyRateLimitTest do
  use WallopWeb.ConnCase, async: false

  alias WallopWeb.Plugs.KeyRateLimit

  setup do
    KeyRateLimit.ensure_table()
    KeyRateLimit.reset()
    :ok
  end

  defp conn_with_key(api_key_id) do
    build_conn()
    |> assign(:api_key, %{id: api_key_id})
  end

  describe "no api key assigned" do
    test "passes through without rate limiting" do
      result = KeyRateLimit.call(build_conn(), [])
      refute result.halted
    end
  end

  describe "under the limit" do
    test "allows 60 requests in a window" do
      conn = conn_with_key("key-a")

      for _ <- 1..60 do
        result = KeyRateLimit.call(conn, [])
        refute result.halted
      end
    end
  end

  describe "at the limit" do
    test "blocks request #61 with 429 and Retry-After header" do
      conn = conn_with_key("key-b")

      for _ <- 1..60 do
        KeyRateLimit.call(conn, [])
      end

      result = KeyRateLimit.call(conn, [])
      assert result.halted
      assert result.status == 429

      assert [retry_after] = Plug.Conn.get_resp_header(result, "retry-after")
      assert {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0
    end
  end

  describe "separate limits per key" do
    test "different keys have independent counters" do
      conn_a = conn_with_key("key-c")
      conn_b = conn_with_key("key-d")

      for _ <- 1..60 do
        KeyRateLimit.call(conn_a, [])
      end

      result_b = KeyRateLimit.call(conn_b, [])
      refute result_b.halted

      result_a = KeyRateLimit.call(conn_a, [])
      assert result_a.halted
    end
  end
end
