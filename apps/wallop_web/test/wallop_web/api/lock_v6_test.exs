defmodule WallopWeb.Api.LockV6Test do
  use WallopWeb.ConnCase, async: false
  import WallopCore.TestHelpers

  alias WallopCore.Weather.Schedule

  defp api(conn, key) do
    conn
    |> put_req_header("authorization", "Bearer #{key.__metadata__.raw_key}")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp lock(key, draw, attrs, status) do
    build_conn()
    |> api(key)
    |> patch("/api/v1/draws/#{draw.id}/lock", %{
      "data" => %{"type" => "draw", "id" => draw.id, "attributes" => attrs}
    })
    |> json_response(status)
  end

  defp top_of_hour(hours),
    do:
      DateTime.utc_now()
      |> DateTime.add(hours * 3600)
      |> DateTime.truncate(:second)
      |> then(&%{&1 | minute: 0, second: 0})

  setup do
    ensure_infrastructure_key()
    :ok
  end

  describe "observation-weather operators" do
    setup do
      {_op, key} = create_v6_operator()
      %{key: key, draw: open_draw_with_entries(key)}
    end

    test "a late draw_at returns 400 with meta.latest_lock_at; the draw can still lock", %{
      key: key,
      draw: draw
    } do
      late = top_of_hour(-1)
      {:ok, s} = Schedule.schedule(late)
      latest = s.latest_lock_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      # Whole seconds: the observation hour minus 46 minutes.
      assert latest =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:14:00Z\z/

      [error] = lock(key, draw, %{"draw_at" => DateTime.to_iso8601(late)}, 400)["errors"]

      assert error["status"] == "400"
      assert error["code"] == "invalid_argument"
      assert error["source"]["pointer"] == "/data/attributes/draw_at"
      assert error["meta"]["latest_lock_at"] == latest
      assert {:ok, _, 0} = DateTime.from_iso8601(error["meta"]["latest_lock_at"])
      assert error["detail"] == "is too late: this draw must be locked by #{latest}"

      ok = lock(key, draw, %{}, 200)
      assert ok["data"]["attributes"]["status"] == "awaiting_entropy"
      assert {:ok, _, 0} = DateTime.from_iso8601(ok["data"]["attributes"]["expected_result_at"])
    end

    test "draw_at sets expected_result_at", %{key: key, draw: draw} do
      draw_at = top_of_hour(3)
      ok = lock(key, draw, %{"draw_at" => DateTime.to_iso8601(draw_at)}, 200)
      {:ok, expected, 0} = DateTime.from_iso8601(ok["data"]["attributes"]["expected_result_at"])
      assert DateTime.compare(expected, draw_at) == :eq
    end

    test "weather_time is refused as an unknown input, pointing at weather_time", %{
      key: key,
      draw: draw
    } do
      [error] =
        lock(key, draw, %{"weather_time" => DateTime.to_iso8601(top_of_hour(3))}, 400)["errors"]

      # weather_time is no longer a lock input: the body is refused.
      assert error["source"]["pointer"] == "/data/attributes/weather_time"
      assert error["code"] == "invalid_body"
    end
  end

  describe "when the fetching service isn't ready" do
    test "an observation lock is a 400 observation_paused with no pointer; the draw stays open" do
      {_op, key} = create_v6_operator()
      put_observation_readiness!(nil)
      draw = open_draw_with_entries(key)

      for attrs <- [%{"draw_at" => DateTime.to_iso8601(top_of_hour(3))}, %{}] do
        [error] = lock(key, draw, attrs, 400)["errors"]

        assert error["status"] == "400"
        assert error["code"] == "observation_paused"
        assert error["source"] in [nil, %{}]
        assert error["meta"] in [nil, %{}]

        assert error["detail"] ==
                 "observation-weather draws are paused here: Land Observations readings can't be fetched right now"
      end

      assert Ash.get!(WallopCore.Resources.Draw, draw.id, authorize?: false).status == :open
    end
  end

  describe "a late refusal at signing" do
    alias WallopCore.Resources.Draw.Changes.SignAndStoreReceipt

    defp render(error),
      do:
        AshJsonApi.Error.to_json_api_errors(
          WallopCore.Domain,
          WallopCore.Resources.Draw,
          %Ash.Error.Invalid{errors: [error]},
          :update
        )

    @wt ~U[2026-10-14 19:00:00.000000Z]
    @late ~U[2026-10-14 18:14:00.000001Z]

    test "with draw_at sent, it points at draw_at" do
      [error] = render(SignAndStoreReceipt.v6_lock_time_error(@late, @wt, :draw_at))
      assert error.source_pointer == "/data/attributes/draw_at"
      assert error.code == "invalid_argument"
      assert error.meta[:latest_lock_at] == "2026-10-14T18:14:00Z"
    end

    test "without draw_at, it is an action-level error with no pointer" do
      [error] = render(SignAndStoreReceipt.v6_lock_time_error(@late, @wt, nil))
      assert error.source_pointer in [nil, :undefined]
      assert error.status_code == 400
      assert error.code == "invalid_argument"
      assert error.meta[:latest_lock_at] == "2026-10-14T18:14:00Z"
      assert error.detail =~ "is too late: this draw must be locked by"
    end
  end
end
