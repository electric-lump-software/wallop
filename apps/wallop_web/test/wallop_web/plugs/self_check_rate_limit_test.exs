defmodule WallopWeb.Plugs.SelfCheckRateLimitTest do
  use WallopWeb.ConnCase, async: false

  alias WallopWeb.Plugs.SelfCheckRateLimit

  setup do
    SelfCheckRateLimit.reset()
    :ok
  end

  describe "call/2" do
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
