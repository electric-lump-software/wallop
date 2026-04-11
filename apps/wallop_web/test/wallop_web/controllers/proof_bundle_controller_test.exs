defmodule WallopWeb.ProofBundleControllerTest do
  use WallopWeb.ConnCase, async: false

  describe "GET /proof/:id.json" do
    test "returns 200 with canonical proof bundle for completed draw", %{conn: conn} do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{executed.id}.json")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/json; charset=utf-8"
             ]

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]

      bundle = Jason.decode!(conn.resp_body)
      assert bundle["version"] == 1
      assert bundle["draw_id"] == executed.id
    end

    test "endpoint output matches WallopCore.ProofBundle.build/1 byte-for-byte", %{conn: conn} do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{executed.id}.json")
      {:ok, expected_bytes} = WallopCore.ProofBundle.build(executed)

      assert conn.resp_body == expected_bytes
    end

    test "returns 404 for unknown draw", %{conn: conn} do
      conn = get(conn, "/proof/00000000-0000-0000-0000-000000000000.json")
      assert conn.status == 404
    end

    test "returns 404 for non-completed draw", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key)

      conn = get(conn, "/proof/#{draw.id}.json")
      assert conn.status == 404
    end
  end
end
