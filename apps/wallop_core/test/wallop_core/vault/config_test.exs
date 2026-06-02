defmodule WallopCore.Vault.ConfigTest do
  use ExUnit.Case, async: true

  alias WallopCore.Vault.Config

  # Two distinct, valid base64 AES-256 keys.
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
    # Wave A pins @current_tag=V1, @previous_tag=V0 — the same pair as
    # production today. The placeholder guard refuses dual-key mode
    # until @current_tag is bumped past V1. The dual-cipher shape tests
    # therefore have to live behind that guard until the first real
    # rotation. Once the tag is bumped, re-enable the shape assertions
    # and delete the placeholder-guard test.
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

    # VAULT_KEY_OLD-naming coverage: the dual-cipher path that would
    # surface VAULT_KEY_OLD in the decode error is gated behind the
    # Wave-A placeholder guard. Re-enable at first rotation, when the
    # guard is removed and dual-cipher decode_key!/2 becomes reachable.
  end

  describe "tag constants" do
    test "current and previous tags differ — required for Cloak routing" do
      refute Config.current_tag() == Config.previous_tag()
    end

    test "current tag matches the production V1 value" do
      # If you bump this, you are starting a rotation. Read
      # `WallopCore.Vault.Config` and the rotation runbook first.
      assert Config.current_tag() == "AES.GCM.V1"
    end
  end
end
