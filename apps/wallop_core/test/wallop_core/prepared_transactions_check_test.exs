defmodule WallopCore.PreparedTransactionsCheckTest do
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias WallopCore.PreparedTransactionsCheck

  setup do
    test_pid = self()
    handler = "prepared-transactions-check-#{inspect(test_pid)}"

    :telemetry.attach(
      handler,
      PreparedTransactionsCheck.event(),
      fn _event, measurements, _meta, _ -> send(test_pid, {:alert, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "\"0\" is fine: no log, no event" do
    log = capture_log(fn -> assert PreparedTransactionsCheck.report("0") == :ok end)
    refute log =~ "max_prepared_transactions"
    refute_received {:alert, _}
  end

  test "any other value logs an error and emits telemetry" do
    log =
      capture_log(fn -> assert PreparedTransactionsCheck.report("10") == {:alert, "10"} end)

    assert log =~ "[error]"
    assert log =~ "max_prepared_transactions is 10, not 0"
    assert_received {:alert, %{max_prepared_transactions: 10}}
  end

  test "run/0 reads the test database, which has prepared transactions off" do
    assert PreparedTransactionsCheck.run() == :ok
  end

  test "it is off in the test config and starts only when enabled" do
    assert Application.get_env(:wallop_core, :prepared_transactions_check) == false

    assert %{restart: :temporary, start: {Task, :start_link, [_]}} =
             PreparedTransactionsCheck.child_spec([])
  end
end
