defmodule WallopCore.VaultHealthCheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias WallopCore.VaultHealthCheck

  setup do
    original = Application.get_env(:wallop_core, WallopCore.Vault)
    original_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Application.put_env(:wallop_core, WallopCore.Vault, original)
      Logger.configure(level: original_level)
    end)

    :ok
  end

  describe "single-cipher mode" do
    test "round-trips :default and logs an OK line tagged with the current generation" do
      log =
        capture_log([level: :info], fn ->
          assert :ok = VaultHealthCheck.check!(WallopCore.Vault)
        end)

      assert log =~ "Vault round-trip OK"
      assert log =~ "label=:default"
      assert log =~ "tag=AES.GCM.V1"
      refute log =~ "DUAL-KEY rotation"
    end
  end

  describe "boot refusal" do
    test "raises when no ciphers are configured" do
      Application.put_env(:wallop_core, WallopCore.Vault, ciphers: [])

      assert_raise RuntimeError, ~r/no configured ciphers/, fn ->
        VaultHealthCheck.check!(WallopCore.Vault)
      end
    end
  end
end
