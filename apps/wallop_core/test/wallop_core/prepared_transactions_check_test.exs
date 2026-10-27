defmodule WallopCore.PreparedTransactionsCheckTest do
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias WallopCore.PreparedTransactionsCheck, as: Check

  setup do
    test_pid = self()
    handler = "prepared-transactions-check-#{inspect(test_pid)}"

    :telemetry.attach_many(
      handler,
      [Check.event(), Check.unreadable_event()],
      fn event, measurements, _meta, _ -> send(test_pid, {event, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp reader(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn ->
      case Agent.get_and_update(agent, &next/1) do
        {:raise, message} -> raise message
        value -> value
      end
    end
  end

  defp next([]), do: {"0", []}
  defp next([h | t]), do: {h, t}

  test "\"0\" is fine: no log, no event" do
    log = capture_log(fn -> assert Check.run(reader(["0"]), 0) == :ok end)
    refute log =~ "max_prepared_transactions"
    refute_received {_, _}
  end

  test "any other value logs an error and emits telemetry" do
    log = capture_log(fn -> assert Check.run(reader(["10"]), 0) == {:alert, "10"} end)
    assert log =~ "[error]"
    assert log =~ "max_prepared_transactions is 10, not 0"

    assert_received {[:wallop_core, :db, :prepared_transactions_enabled],
                     %{max_prepared_transactions: 10}}
  end

  test "a failed read is retried once; a good second read is reported as usual" do
    log =
      capture_log(fn ->
        assert Check.run(reader([{:raise, "connection refused"}, "0"]), 0) == :ok
      end)

    refute log =~ "[error]"
    refute_received {_, _}
  end

  test "two failed reads log an error and emit the unreadable event" do
    log =
      capture_log(fn ->
        assert {:unreadable, "connection refused"} =
                 Check.run(reader([{:raise, "boom"}, {:raise, "connection refused"}]), 0)
      end)

    assert log =~ "[error]"
    assert log =~ "Could not read max_prepared_transactions (retried once)"
    assert_received {[:wallop_core, :db, :prepared_transactions_unreadable], %{count: 1}}
  end

  test "run/0 reads the test database, which has prepared transactions off" do
    assert Check.run() == :ok
  end

  test "the process checks at start and then on every interval" do
    read = reader(["10", "11", "0", "0", "0", "0", "0", "0", "0", "0"])

    capture_log(fn ->
      pid = start_supervised!({Check, interval_ms: 20, retry_delay_ms: 0, read: read})

      assert_receive {[:wallop_core, :db, :prepared_transactions_enabled],
                      %{max_prepared_transactions: 10}},
                     1_000

      assert_receive {[:wallop_core, :db, :prepared_transactions_enabled],
                      %{max_prepared_transactions: 11}},
                     1_000

      stop_supervised!(Check)
      refute Process.alive?(pid)
    end)
  end

  test "it is off in the test config" do
    assert Application.get_env(:wallop_core, :prepared_transactions_check) == false

    refute Enum.any?(
             Supervisor.which_children(WallopCore.Supervisor),
             &match?({Check, _, _, _}, &1)
           )
  end
end
