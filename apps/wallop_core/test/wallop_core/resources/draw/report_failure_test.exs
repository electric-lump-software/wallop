defmodule WallopCore.Resources.Draw.ReportFailureTest do
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers

  defp mark_failed(draw, extra \\ & &1) do
    draw
    |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "drand unavailable"})
    |> extra.()
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
  end

  test "a failed draw logs an error and emits telemetry" do
    draw = create_draw(create_api_key())
    ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :draw, :failed]])

    log = capture_log(fn -> assert {:ok, _} = mark_failed(draw) end)

    assert log =~ "[error]"
    assert log =~ "drand unavailable"
    draw_id = draw.id

    assert_received {[:wallop_core, :draw, :failed], ^ref, %{count: 1},
                     %{draw_id: ^draw_id, failure_reason: "drand unavailable"}}
  end

  test "a failure that rolls back is not reported" do
    draw = create_draw(create_api_key())
    ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :draw, :failed]])

    # A later hook in the same transaction fails, as a failed webhook insert would.
    log =
      capture_log(fn ->
        assert {:error, _} =
                 mark_failed(
                   draw,
                   &Ash.Changeset.after_action(&1, fn _, _ -> {:error, "boom"} end)
                 )
      end)

    refute log =~ "drand unavailable"
    refute_received {[:wallop_core, :draw, :failed], ^ref, _, _}
    assert Ash.get!(WallopCore.Resources.Draw, draw.id, authorize?: false).status != :failed
  end
end
