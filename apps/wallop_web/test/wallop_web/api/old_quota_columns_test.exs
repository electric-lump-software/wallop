defmodule WallopWeb.Api.OldQuotaColumnsTest do
  use WallopWeb.ConnCase, async: true

  defp key_with_raw do
    operator = create_operator()

    {:ok, key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: "k", operator_id: operator.id})
      |> Ash.create(authorize?: false)

    {key, key.__metadata__.raw_key}
  end

  defp api(conn, raw_key) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp draw_payload, do: %{"data" => %{"type" => "draw", "attributes" => %{"winner_count" => 1}}}

  defp exhaust_old_quota(key) do
    WallopCore.Repo.query!(
      "UPDATE api_keys SET tier = 'frozen', monthly_draw_limit = 0, monthly_draw_count = 5, count_reset_at = now() + interval '7 days' WHERE id = $1",
      [Ecto.UUID.dump!(key.id)]
    )
  end

  test "a key whose old quota columns say it is out of draws can still create one", %{
    conn: conn
  } do
    {key, raw} = key_with_raw()
    exhaust_old_quota(key)

    assert conn |> api(raw) |> post("/api/v1/draws", draw_payload()) |> json_response(201)
  end

  test "an open draw still finishes after its key's old quota columns change", %{conn: conn} do
    {key, raw} = key_with_raw()

    created = conn |> api(raw) |> post("/api/v1/draws", draw_payload()) |> json_response(201)
    draw_id = created["data"]["id"]

    exhaust_old_quota(key)

    entries = %{
      "data" => %{
        "type" => "draw",
        "id" => draw_id,
        "attributes" => %{
          "entries" => [%{"weight" => 1}, %{"weight" => 1}],
          "client_ref" => Ash.UUID.generate()
        }
      }
    }

    assert build_conn()
           |> api(raw)
           |> patch("/api/v1/draws/#{draw_id}/entries", entries)
           |> json_response(200)

    lock = %{"data" => %{"type" => "draw", "id" => draw_id, "attributes" => %{}}}

    assert %{"data" => %{"attributes" => %{"status" => "awaiting_entropy"}}} =
             build_conn()
             |> api(raw)
             |> patch("/api/v1/draws/#{draw_id}/lock", lock)
             |> json_response(200)

    assert build_conn() |> api(raw) |> post("/api/v1/draws", draw_payload()) |> json_response(201)
  end
end
