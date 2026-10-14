defmodule WallopWeb.Plugs.TierLimitTest do
  use WallopWeb.ConnCase, async: false

  import WallopWeb.RateLimitHelpers

  alias WallopWeb.Plugs.TierLimit

  setup do
    Phoenix.PubSub.subscribe(WallopCore.PubSub, "rate_limit_pressure")

    test_pid = self()
    id = "tier-limit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:wallop_web, :rate_limit, :quota_limited],
      fn [:wallop_web, :rate_limit, kind], %{count: 1}, meta, _ ->
        send(test_pid, {:telemetry, kind, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

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

      api_key =
        WallopCore.TestHelpers.create_api_key(%{
          monthly_draw_limit: 10,
          monthly_draw_count: 10,
          count_reset_at: future,
          tier: "starter"
        })

      result = TierLimit.call(conn_with_key(api_key), [])
      assert result.halted
      assert result.status == 429

      body = Jason.decode!(result.resp_body)
      assert [error] = body["errors"]
      assert error["code"] == "tier_limit_exceeded"
      assert error["meta"]["tier"] == "starter"
      assert error["meta"]["limit"] == 10
      assert error["title"] == "Too many requests"
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

  describe "quota 429" do
    test "carries Retry-After until count_reset_at and signals quota_limited" do
      reset_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      api_key =
        WallopCore.TestHelpers.create_api_key(%{
          monthly_draw_limit: 1,
          monthly_draw_count: 1,
          count_reset_at: reset_at,
          tier: "starter"
        })

      conn = TierLimit.call(conn_with_key(api_key), [])

      assert conn.status == 429
      assert [ra] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert String.to_integer(ra) in 3590..3600

      id = api_key.id

      assert_receive {:rate_limit_pressure, %{api_key_id: ^id, kind: :quota_limited, limit: 1}},
                     1_000

      assert_receive {:telemetry, :quota_limited, %{api_key_id: ^id, limit: 1}}
    end

    test "limit 0 with no reset date is a clean 429 with a day-long Retry-After" do
      api_key =
        WallopCore.TestHelpers.create_api_key(%{
          monthly_draw_limit: 0,
          count_reset_at: nil,
          tier: "frozen"
        })

      conn = TierLimit.call(conn_with_key(api_key), [])

      assert conn.status == 429
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["86400"]
    end

    test "limit 0 with a reset date that has just passed retries in a second" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      api_key =
        WallopCore.TestHelpers.create_api_key(%{
          monthly_draw_limit: 0,
          count_reset_at: past,
          tier: "frozen"
        })

      conn = TierLimit.call(conn_with_key(api_key), [])

      assert conn.status == 429
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]
    end

    test "Retry-After rounds a part-second up" do
      reset_at = DateTime.add(DateTime.utc_now(), 1500, :millisecond)

      api_key =
        WallopCore.TestHelpers.create_api_key(%{
          monthly_draw_limit: 1,
          monthly_draw_count: 1,
          count_reset_at: reset_at,
          tier: "starter"
        })

      conn = TierLimit.call(conn_with_key(api_key), [])
      assert [ra] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert String.to_integer(ra) in 2..3
    end

    test "a second quota 429 in the same minute signals no second time" do
      await_fresh_window()

      api_key =
        WallopCore.TestHelpers.create_api_key(%{
          monthly_draw_limit: 1,
          monthly_draw_count: 1,
          count_reset_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          tier: "starter"
        })

      assert TierLimit.call(conn_with_key(api_key), []).status == 429
      assert TierLimit.call(conn_with_key(api_key), []).status == 429

      id = api_key.id
      assert_receive {:rate_limit_pressure, %{api_key_id: ^id, kind: :quota_limited}}, 1_000
      refute_receive {:rate_limit_pressure, %{api_key_id: ^id}}, 200
      assert_receive {:telemetry, :quota_limited, %{api_key_id: ^id}}
      refute_receive {:telemetry, _, %{api_key_id: ^id}}, 50
    end
  end
end
