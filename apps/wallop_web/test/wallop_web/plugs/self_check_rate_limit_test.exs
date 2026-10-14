defmodule WallopWeb.Plugs.SelfCheckRateLimitTest do
  use WallopWeb.ConnCase, async: false

  import WallopWeb.RateLimitHelpers

  alias WallopWeb.Plugs.SelfCheckRateLimit

  setup do
    WallopWeb.RateLimiter.reset()
    await_fresh_window()
    :ok
  end

  describe "call/2" do
    test "IPv6 clients in one /64 share a budget", %{conn: conn} do
      a = %{conn | remote_ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}, params: %{"entry_id" => "abc"}}
      b = %{conn | remote_ip: {0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}, params: %{"entry_id" => "abc"}}

      for _ <- 1..60, do: SelfCheckRateLimit.call(a, [])

      assert SelfCheckRateLimit.call(b, []).halted
    end

    test "no-op for proof page GET with no entry_id", %{conn: conn} do
      # Same IP, many requests — none carrying an entry_id. Must not rate-limit.
      for _ <- 1..100 do
        result = SelfCheckRateLimit.call(conn, [])
        refute result.halted
        refute result.status == 429
      end
    end

    test "allows 60 self-checks per minute per IP", %{conn: conn} do
      conn_with_check = Plug.Conn.put_private(conn, :phoenix_action, :show)
      conn_with_check = %{conn_with_check | params: %{"entry_id" => "abc"}}

      for _ <- 1..60 do
        result = SelfCheckRateLimit.call(conn_with_check, [])
        refute result.halted
      end
    end

    test "blocks 61st self-check within the window", %{conn: conn} do
      conn_with_check = %{conn | params: %{"entry_id" => "abc"}}

      for _ <- 1..60, do: SelfCheckRateLimit.call(conn_with_check, [])

      result = SelfCheckRateLimit.call(conn_with_check, [])
      assert result.halted
      assert result.status == 429
      [ra] = Plug.Conn.get_resp_header(result, "retry-after")
      assert String.to_integer(ra) in 1..60
    end

    test "separate IPs have separate quotas", %{conn: conn} do
      a = %{conn | remote_ip: {1, 1, 1, 1}, params: %{"entry_id" => "abc"}}
      b = %{conn | remote_ip: {2, 2, 2, 2}, params: %{"entry_id" => "abc"}}

      for _ <- 1..60, do: SelfCheckRateLimit.call(a, [])

      # a is at the limit; b should still be allowed
      refute SelfCheckRateLimit.call(b, []).halted
      assert SelfCheckRateLimit.call(a, []).halted
    end
  end
end
