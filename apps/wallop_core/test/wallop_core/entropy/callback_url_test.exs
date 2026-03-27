defmodule WallopCore.Entropy.CallbackUrlTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.CallbackUrl

  describe "validate/1" do
    test "accepts valid HTTPS URL" do
      assert :ok = CallbackUrl.validate("https://example.com/webhook")
    end

    test "accepts HTTPS with port" do
      assert :ok = CallbackUrl.validate("https://example.com:8443/webhook")
    end

    test "rejects HTTP URL" do
      assert {:error, "must be HTTPS"} = CallbackUrl.validate("http://example.com/webhook")
    end

    test "rejects localhost" do
      assert {:error, _} = CallbackUrl.validate("https://localhost/webhook")
    end

    test "rejects 127.0.0.1" do
      assert {:error, _} = CallbackUrl.validate("https://127.0.0.1/webhook")
    end

    test "rejects 10.x.x.x" do
      assert {:error, _} = CallbackUrl.validate("https://10.0.0.1/webhook")
    end

    test "rejects 172.16.x.x" do
      assert {:error, _} = CallbackUrl.validate("https://172.16.0.1/webhook")
    end

    test "rejects 192.168.x.x" do
      assert {:error, _} = CallbackUrl.validate("https://192.168.1.1/webhook")
    end

    test "rejects malformed URL" do
      assert {:error, _} = CallbackUrl.validate("not-a-url")
    end

    test "rejects nil" do
      assert {:error, _} = CallbackUrl.validate(nil)
    end

    test "rejects 169.254.x.x link-local address" do
      assert {:error, _} = CallbackUrl.validate("https://169.254.169.254/hook")
    end

    test "rejects 100.64.x.x CGNAT shared address space" do
      assert {:error, _} = CallbackUrl.validate("https://100.64.0.1/hook")
    end

    test "rejects 100.127.x.x CGNAT shared address space upper bound" do
      assert {:error, _} = CallbackUrl.validate("https://100.127.255.255/hook")
    end

    test "rejects 0.0.0.0" do
      assert {:error, _} = CallbackUrl.validate("https://0.0.0.0/hook")
    end

    test "rejects ::1 IPv6 loopback" do
      assert {:error, _} = CallbackUrl.validate("https://[::1]/hook")
    end

    test "rejects URL with no host" do
      assert {:error, _} = CallbackUrl.validate("https:///path")
    end

    test "rejects URL with empty scheme" do
      assert {:error, _} = CallbackUrl.validate("://example.com/hook")
    end
  end
end
