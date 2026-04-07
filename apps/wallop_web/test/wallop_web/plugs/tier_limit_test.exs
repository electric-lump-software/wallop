defmodule WallopWeb.Plugs.TierLimitTest do
  use WallopWeb.ConnCase, async: false

  alias WallopWeb.Plugs.TierLimit

  defp conn_with_key(api_key, method \\ "POST", path \\ ["draws"]) do
    %{build_conn() | method: method, path_info: path}
    |> assign(:api_key, api_key)
  end

  describe "non-draw-create requests" do
    test "passes through GET /draws/:id" do
      conn =
        conn_with_key(%{monthly_draw_limit: 1, monthly_draw_count: 5}, "GET", ["draws", "abc"])

      result = TierLimit.call(conn, [])
      refute result.halted
    end

    test "passes through POST to other paths" do
      conn =
        conn_with_key(
          %{monthly_draw_limit: 1, monthly_draw_count: 5},
          "POST",
          ["api_keys"]
        )

      result = TierLimit.call(conn, [])
      refute result.halted
    end
  end

  describe "no actor" do
    test "passes through" do
      conn = %{build_conn() | method: "POST", path_info: ["draws"]}
      result = TierLimit.call(conn, [])
      refute result.halted
    end
  end

  describe "unlimited tier (nil limit)" do
    test "passes through regardless of count" do
      conn =
        conn_with_key(%{
          monthly_draw_limit: nil,
          monthly_draw_count: 999_999,
          count_reset_at: nil,
          tier: nil
        })

      result = TierLimit.call(conn, [])
      refute result.halted
    end
  end

  describe "under the limit" do
    test "passes through" do
      future = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)

      conn =
        conn_with_key(%{
          monthly_draw_limit: 10,
          monthly_draw_count: 9,
          count_reset_at: future,
          tier: "starter"
        })

      result = TierLimit.call(conn, [])
      refute result.halted
    end
  end

  describe "at the limit" do
    test "rejects with 429 and tier metadata" do
      future = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)

      conn =
        conn_with_key(%{
          monthly_draw_limit: 10,
          monthly_draw_count: 10,
          count_reset_at: future,
          tier: "starter"
        })

      result = TierLimit.call(conn, [])
      assert result.halted
      assert result.status == 429

      body = Jason.decode!(result.resp_body)
      assert [error] = body["errors"]
      assert error["code"] == "tier_limit_exceeded"
      assert error["meta"]["tier"] == "starter"
      assert error["meta"]["limit"] == 10
      assert error["detail"] =~ "Upgrade at"
    end
  end

  describe "expired count window" do
    test "treats count as 0 if reset_at is in the past" do
      past = DateTime.add(DateTime.utc_now(), -86_400, :second)

      conn =
        conn_with_key(%{
          monthly_draw_limit: 10,
          monthly_draw_count: 100,
          count_reset_at: past,
          tier: "starter"
        })

      result = TierLimit.call(conn, [])
      refute result.halted
    end
  end
end
