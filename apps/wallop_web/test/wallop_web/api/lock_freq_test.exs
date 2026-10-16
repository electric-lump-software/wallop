defmodule WallopWeb.Api.LockFreqTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Frequency.Schedule
  alias WallopCore.Resources.Draw.Changes.SignAndStoreReceipt

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

  defp minute_after(seconds),
    do:
      DateTime.utc_now()
      |> DateTime.add(seconds)
      |> DateTime.truncate(:second)
      |> then(&%{&1 | second: 0})

  setup do
    ensure_infrastructure_key()
    :ok
  end

  describe "grid-frequency operators" do
    setup do
      {_op, key} = create_freq_operator()
      %{key: key, draw: open_draw_with_entries(key)}
    end

    test "a late draw_at returns 400 with meta.latest_lock_at = T - 60 s; the draw can still lock",
         %{key: key, draw: draw} do
      late = minute_after(360)
      {:ok, s} = Schedule.schedule(late)
      latest = s.latest_lock_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      # Whole seconds, on the 15-second grid of window starts.
      assert latest =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:(00|15|30|45)Z\z/

      [error] = lock(key, draw, %{"draw_at" => DateTime.to_iso8601(late)}, 400)["errors"]

      assert error["status"] == "400"
      assert error["code"] == "invalid_argument"
      assert error["source"]["pointer"] == "/data/attributes/draw_at"
      assert error["meta"] == %{"latest_lock_at" => latest}
      assert {:ok, _, 0} = DateTime.from_iso8601(error["meta"]["latest_lock_at"])
      assert error["detail"] == "is too late: this draw must be locked by #{latest}"

      ok = lock(key, draw, %{}, 200)["data"]["attributes"]
      assert ok["status"] == "awaiting_entropy"
      assert {:ok, _, 0} = DateTime.from_iso8601(ok["expected_result_at"])
      assert {:ok, _, 0} = DateTime.from_iso8601(ok["freq_start"])
      assert {ok["weather_station"], ok["weather_time"], ok["freq_value"]} == {nil, nil, nil}
    end

    test "draw_at sets expected_result_at; the response has the same keys as every draw's",
         %{key: key, draw: draw} do
      draw_at = minute_after(3600)
      {:ok, s} = Schedule.schedule(draw_at)

      attrs =
        lock(key, draw, %{"draw_at" => DateTime.to_iso8601(draw_at)}, 200)["data"]["attributes"]

      {:ok, expected, 0} = DateTime.from_iso8601(attrs["expected_result_at"])
      assert DateTime.compare(expected, draw_at) == :eq
      {:ok, t, 0} = DateTime.from_iso8601(attrs["freq_start"])
      assert DateTime.compare(t, s.freq_start) == :eq
      assert attrs |> Map.keys() |> Enum.sort() == draw_attribute_keys()
    end

    test "weather_time is refused, pointing at weather_time", %{key: key, draw: draw} do
      [error] =
        lock(key, draw, %{"weather_time" => DateTime.to_iso8601(minute_after(3600))}, 400)[
          "errors"
        ]

      assert error["source"]["pointer"] == "/data/attributes/weather_time"
      assert error["detail"] == "can't be set for this operator; send draw_at instead"
    end
  end

  describe "a late grid-frequency refusal at signing" do
    defp render(error),
      do:
        AshJsonApi.Error.to_json_api_errors(
          WallopCore.Domain,
          WallopCore.Resources.Draw,
          %Ash.Error.Invalid{errors: [error]},
          :update
        )

    @t ~U[2026-10-14 19:54:15.000000Z]
    @late ~U[2026-10-14 19:53:15.000001Z]

    test "with draw_at sent, it points at draw_at" do
      [error] = render(SignAndStoreReceipt.freq_lock_time_error(@late, @t, :draw_at))
      assert error.source_pointer == "/data/attributes/draw_at"
      assert error.status_code == 400
      assert error.code == "invalid_argument"
      assert error.meta[:latest_lock_at] == "2026-10-14T19:53:15Z"
    end

    test "without draw_at, it is an action-level error with no pointer" do
      [error] = render(SignAndStoreReceipt.freq_lock_time_error(@late, @t, nil))
      assert error.source_pointer in [nil, :undefined]
      assert error.status_code == 400
      assert error.code == "invalid_argument"
      assert error.meta[:latest_lock_at] == "2026-10-14T19:53:15Z"
      assert error.detail == "is too late: this draw must be locked by 2026-10-14T19:53:15Z"
    end
  end

  # Every draw's JSON attributes: the same set a forecast lock returns.
  defp draw_attribute_keys,
    do: ~w(callback_url check_url drand_chain drand_randomness drand_response drand_round
           drand_signature entry_canonical entry_count entry_hash executed_at
           expected_result_at failed_at failure_reason freq_fallback_reason freq_start
           freq_value metadata name operator_id
           operator_sequence results seed seed_json seed_source stage_timestamps status
           weather_fallback_reason weather_observation_time weather_raw weather_station
           weather_time weather_value winner_count)
end
