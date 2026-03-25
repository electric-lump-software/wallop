defmodule WallopWeb.Plugs.RateLimitTest do
  use WallopWeb.ConnCase, async: false

  alias WallopWeb.Plugs.RateLimit

  setup do
    RateLimit.ensure_table()
    RateLimit.reset()
    :ok
  end

  defp conn_with_ip(ip_tuple) do
    %{build_conn() | remote_ip: ip_tuple}
  end

  describe "under the limit" do
    test "allows requests under 10" do
      conn = conn_with_ip({127, 0, 0, 1})

      for _ <- 1..10 do
        result = RateLimit.call(conn, [])
        refute result.halted
      end
    end
  end

  describe "at the limit" do
    test "blocks request #11 with 429" do
      conn = conn_with_ip({10, 0, 0, 1})

      for _ <- 1..10 do
        result = RateLimit.call(conn, [])
        refute result.halted
      end

      result = RateLimit.call(conn, [])
      assert result.halted
      assert result.status == 429
    end
  end

  describe "separate limits per IP" do
    test "different IPs have independent counters" do
      conn_a = conn_with_ip({192, 168, 1, 1})
      conn_b = conn_with_ip({192, 168, 1, 2})

      for _ <- 1..10 do
        result = RateLimit.call(conn_a, [])
        refute result.halted
      end

      # IP A is now at the limit — IP B should still be allowed
      result_b = RateLimit.call(conn_b, [])
      refute result_b.halted

      # IP A should be blocked
      result_a = RateLimit.call(conn_a, [])
      assert result_a.halted
      assert result_a.status == 429
    end
  end

  describe "reset/0" do
    test "clears all counters so previously blocked IP is allowed again" do
      conn = conn_with_ip({172, 16, 0, 1})

      for _ <- 1..10 do
        RateLimit.call(conn, [])
      end

      blocked = RateLimit.call(conn, [])
      assert blocked.halted

      RateLimit.reset()

      allowed = RateLimit.call(conn, [])
      refute allowed.halted
    end
  end
end
