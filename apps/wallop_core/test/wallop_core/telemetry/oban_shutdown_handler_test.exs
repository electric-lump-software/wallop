defmodule WallopCore.Telemetry.ObanShutdownHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WallopCore.Telemetry.ObanShutdownHandler

  @event [:oban, :queue, :shutdown]

  test "logs an error naming the queue and job ids when jobs are orphaned" do
    log =
      capture_log([level: :error], fn ->
        ObanShutdownHandler.handle_event(
          @event,
          %{elapsed: 100},
          %{orphaned: [41, 42], queue: "weather"},
          nil
        )
      end)

    assert log =~ "[error]"
    assert log =~ "Oban queue weather shut down with orphaned jobs: [41, 42]"
  end

  test "logs nothing when no jobs are orphaned" do
    log =
      capture_log(fn ->
        ObanShutdownHandler.handle_event(
          @event,
          %{elapsed: 0},
          %{orphaned: [], queue: "weather"},
          nil
        )
      end)

    assert log == ""
  end

  test "is attached when the application starts" do
    handlers = :telemetry.list_handlers(@event)
    assert Enum.any?(handlers, &(&1.id == ObanShutdownHandler))
  end
end
