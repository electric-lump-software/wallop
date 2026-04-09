defmodule WallopWeb.ExecutionReceiptControllerTest do
  use WallopWeb.ConnCase, async: false

  alias WallopCore.Protocol

  describe "GET /operator/:slug/executions" do
    test "returns 404 for unknown operator", %{conn: conn} do
      response =
        conn
        |> get("/operator/nonexistent/executions")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns empty list when operator has no execution receipts", %{conn: conn} do
      operator = create_operator()

      response =
        conn
        |> get("/operator/#{operator.slug}/executions")
        |> json_response(200)

      assert response["count"] == 0
      assert response["execution_receipts"] == []
      assert response["operator"]["slug"] == to_string(operator.slug)
    end

    test "returns execution receipts with ETag and cache headers", %{conn: conn} do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      _executed = execute_draw(draw, test_seed(), api_key)

      resp = get(conn, "/operator/#{operator.slug}/executions")

      assert resp.status == 200

      response = json_response(resp, 200)
      assert response["count"] == 1
      assert length(response["execution_receipts"]) == 1

      [receipt] = response["execution_receipts"]
      assert receipt["sequence"] == 1
      assert is_binary(receipt["draw_id"])
      assert is_binary(receipt["lock_receipt_hash"])
      assert is_binary(receipt["signing_key_id"])
      assert is_map(receipt["payload"])
      assert is_binary(receipt["payload_jcs_b64"])
      assert is_binary(receipt["signature_b64"])

      assert get_resp_header(resp, "cache-control") == ["public, max-age=60"]
      [etag] = get_resp_header(resp, "etag")
      assert String.starts_with?(etag, "W/\"exec-")
    end

    test "returns multiple receipts in sequence order", %{conn: conn} do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      _d1 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      _d2 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      _d3 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))

      response =
        conn
        |> get("/operator/#{operator.slug}/executions")
        |> json_response(200)

      assert response["count"] == 3
      sequences = Enum.map(response["execution_receipts"], & &1["sequence"])
      assert sequences == [1, 2, 3]
    end
  end

  describe "GET /operator/:slug/executions/:sequence" do
    test "returns 404 for unknown operator", %{conn: conn} do
      response =
        conn
        |> get("/operator/nonexistent/executions/1")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns 404 for nonexistent sequence", %{conn: conn} do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _draw = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))

      response =
        conn
        |> get("/operator/#{operator.slug}/executions/999")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns 404 for non-integer sequence", %{conn: conn} do
      operator = create_operator()

      response =
        conn
        |> get("/operator/#{operator.slug}/executions/abc")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns single execution receipt with immutable cache", %{conn: conn} do
      infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _draw = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))

      resp = get(conn, "/operator/#{operator.slug}/executions/1")

      assert resp.status == 200

      response = json_response(resp, 200)
      receipt = response["execution_receipt"]

      assert receipt["sequence"] == 1
      assert receipt["signing_key_id"] == infra_key.key_id
      assert response["operator"]["slug"] == to_string(operator.slug)

      # Immutable cache header
      assert get_resp_header(resp, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]
    end

    test "payload_jcs round-trips and signature verifies", %{conn: conn} do
      infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _draw = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))

      response =
        conn
        |> get("/operator/#{operator.slug}/executions/1")
        |> json_response(200)

      receipt = response["execution_receipt"]
      payload_jcs = Base.decode64!(receipt["payload_jcs_b64"])
      signature = Base.decode64!(receipt["signature_b64"])

      # Signature verifies under the infrastructure key
      assert Protocol.verify_receipt(payload_jcs, signature, infra_key.public_key)

      # Decoded payload matches the structured payload field
      assert Jason.decode!(payload_jcs) == receipt["payload"]
    end
  end
end
