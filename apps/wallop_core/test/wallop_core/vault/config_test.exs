defmodule WallopCore.Vault.ConfigTest do
  use ExUnit.Case, async: true

  alias WallopCore.Vault.Config

  @key_a Base.encode64(:crypto.strong_rand_bytes(32))
  @key_b Base.encode64(:crypto.strong_rand_bytes(32))

  describe "build_ciphers/2 — single-key mode" do
    test "returns a single :default cipher under the current tag" do
      assert [default: {Cloak.Ciphers.AES.GCM, opts}] = Config.build_ciphers(@key_a, nil)
      assert opts[:tag] == Config.current_tag()
      assert opts[:iv_length] == 12
      assert byte_size(opts[:key]) == 32
    end

    test "no nil-arg form also works (backwards-compat default)" do
      assert [default: _] = Config.build_ciphers(@key_a)
    end
  end

  describe "build_ciphers/2 — dual-key mode" do
    test "refuses Wave-A placeholder tags + VAULT_KEY_OLD as a footgun" do
      assert_raise ArgumentError, ~r/Wave-A placeholder tags/, fn ->
        Config.build_ciphers(@key_a, @key_b)
      end
    end

    test "refuses to boot when both keys are identical" do
      assert_raise ArgumentError, ~r/identical/, fn ->
        Config.build_ciphers(@key_a, @key_a)
      end
    end
  end

  describe "key validation" do
    test "raises a specific error when a key is not valid base64" do
      assert_raise ArgumentError, ~r/VAULT_KEY.*not valid base64/s, fn ->
        Config.build_ciphers("not base64 at all !!", nil)
      end
    end

    test "raises when a key decodes to the wrong length" do
      short = Base.encode64(:crypto.strong_rand_bytes(16))

      assert_raise ArgumentError, ~r/32 bytes/, fn ->
        Config.build_ciphers(short, nil)
      end
    end
  end

  describe "tag constants" do
    test "current and previous tags differ — required for Cloak routing" do
      refute Config.current_tag() == Config.previous_tag()
    end

    test "current tag matches the production V1 value" do
      assert Config.current_tag() == "AES.GCM.V1"
    end
  end
end
