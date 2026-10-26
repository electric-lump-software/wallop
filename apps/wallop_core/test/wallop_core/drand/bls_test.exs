defmodule WallopCore.Drand.BlsTest do
  use ExUnit.Case, async: true

  alias WallopCore.Drand.{Bls, Quicknet}
  alias WallopCore.Drand.Bls.Native

  @fixtures "test/fixtures/drand/quicknet_rounds.json"
            |> File.read!()
            |> Jason.decode!()

  @rounds @fixtures["quicknet"]["rounds"]
  @testnet @fixtures["quicknet_t"]
  @r1000 Enum.find(@rounds, &(&1["round"] == 1000))

  defp flip_bit(hex, byte_index, bit) do
    <<pre::binary-size(byte_index), b, post::binary>> = Base.decode16!(hex, case: :lower)

    Base.encode16(<<pre::binary, Bitwise.bxor(b, Bitwise.bsl(1, bit)), post::binary>>,
      case: :lower
    )
  end

  describe "the NIF" do
    test "is loaded, and the boot self-test passes" do
      assert Code.ensure_loaded?(Native)
      assert function_exported?(Native, :verify_g1, 3)
      assert Bls.self_test!() == :ok
    end

    test "the boot self-test refuses a NIF that is missing, unloaded or giving wrong answers" do
      for {native, why} <- [
            {WallopCore.Drand.BlsTest.NoSuchNative, "missing"},
            {WallopCore.Drand.BlsTest.NotLoaded, "not loaded"},
            {WallopCore.Drand.BlsTest.AlwaysTrue, "accepts a forged round"},
            {WallopCore.Drand.BlsTest.AlwaysFalse, "refuses a real round"}
          ] do
        error = assert_raise RuntimeError, fn -> Bls.self_test!(native) end
        assert error.message =~ "refusing to start", why
      end
    end

    test "WallopCore.Application runs the self-test before starting anything" do
      source = File.read!("lib/wallop_core/application.ex")
      [start] = Regex.run(~r/def start\(.*?\n  end\n/s, source)
      [before_children, _] = String.split(start, "Supervisor.start_link", parts: 2)
      assert before_children =~ "Bls.self_test!()"
    end

    test "returns a boolean, false for malformed input, never raising for bad bytes" do
      pk = Quicknet.public_key()
      good = sig(@r1000)

      assert Native.verify_g1(pk, 1000, good) === true
      assert Native.verify_g1(pk, 1000, <<>>) === false
      assert Native.verify_g1(pk, 1000, binary_part(good, 0, 47)) === false
      assert Native.verify_g1(pk, 1000, good <> good) === false
      assert Native.verify_g1(binary_part(pk, 0, 95), 1000, good) === false
      assert Native.verify_g1(:binary.copy(<<0>>, 96), 1000, good) === false
    end

    test "a round outside u64 is a badarg from the NIF, which verify_quicknet never passes on" do
      assert_raise ArgumentError, fn ->
        Native.verify_g1(Quicknet.public_key(), 0x1_0000_0000_0000_0000, sig(@r1000))
      end

      refute Bls.verify_quicknet(0x1_0000_0000_0000_0000, @r1000["signature"])
    end

    test "quicknet-t's own signature verifies under quicknet-t's key (the wrong-key case below is a key difference)" do
      [t | _] = @testnet["rounds"]
      pk = Base.decode16!(@testnet["public_key"], case: :lower)
      assert Native.verify_g1(pk, t["round"], sig(t)) === true
    end
  end

  describe "public key" do
    test "is quicknet's 96-byte G2 key, as published in its chain info" do
      assert byte_size(Quicknet.public_key()) == 96

      assert Base.encode16(Quicknet.public_key(), case: :lower) ==
               @fixtures["quicknet"]["public_key"]

      assert @fixtures["quicknet"]["chain_hash"] == Quicknet.chain_hash()
    end
  end

  describe "verify_quicknet/2 on real rounds" do
    for r <- @rounds do
      @r r
      test "round #{r["round"]} verifies, and its randomness is sha256 of the signature" do
        assert Bls.verify_quicknet(@r["round"], @r["signature"])

        assert :crypto.hash(:sha256, sig(@r)) |> Base.encode16(case: :lower) ==
                 @r["randomness"]
      end
    end
  end

  # Every one of these is quicknet round 33068212 or round 1000 changed in
  # one way. Each must be false, never a raise.
  @t_33068212 Enum.find(@fixtures["quicknet_t"]["rounds"], &(&1["round"] == 33_068_212))
  @r_33068212 Enum.find(@fixtures["quicknet"]["rounds"], &(&1["round"] == 33_068_212))

  describe "verify_quicknet/2 refuses" do
    test "one bit flipped, at the start, the middle and the end" do
      s = @r_33068212["signature"]

      # Bit 7 of byte 0 is the compression flag; also flip ordinary bits.
      for {byte, bit} <- [{0, 7}, {0, 5}, {0, 0}, {24, 3}, {47, 0}] do
        refute Bls.verify_quicknet(33_068_212, flip_bit(s, byte, bit)), "byte #{byte} bit #{bit}"
      end
    end

    test "the round one before and one after" do
      refute Bls.verify_quicknet(33_068_211, @r_33068212["signature"])
      refute Bls.verify_quicknet(33_068_213, @r_33068212["signature"])
      refute Bls.verify_quicknet(999, @r1000["signature"])
      refute Bls.verify_quicknet(1001, @r1000["signature"])
    end

    test "a quicknet-t signature: the same scheme and round, another key" do
      refute Bls.verify_quicknet(33_068_212, @t_33068212["signature"])
    end

    test "47 bytes (G1 length minus one)" do
      refute Bls.verify_quicknet(1000, binary_part(@r1000["signature"], 0, 94))
    end

    test "96 bytes (G2 length)" do
      refute Bls.verify_quicknet(1000, @r1000["signature"] <> @r1000["signature"])
      refute Bls.verify_quicknet(1000, String.duplicate("ab", 96))
    end

    test "non-hex input of the right length" do
      refute Bls.verify_quicknet(1000, String.duplicate("zz", 48))
      refute Bls.verify_quicknet(1000, "0x" <> binary_part(@r1000["signature"], 2, 94))
      refute Bls.verify_quicknet(1000, String.duplicate("é", 48))
    end

    test "uppercase hex of a valid signature" do
      refute Bls.verify_quicknet(1000, String.upcase(@r1000["signature"]))
    end

    test "the all-zero point" do
      refute Bls.verify_quicknet(1000, String.duplicate("00", 48))
    end

    test "the compressed identity point (c0 then 47 zero bytes)" do
      refute Bls.verify_quicknet(1000, "c0" <> String.duplicate("00", 47))
    end

    test "a point not on the curve (x = 1: x^3 + 4 is not a square mod p)" do
      refute Bls.verify_quicknet(1000, "80" <> String.duplicate("00", 46) <> "01")
    end

    test "a point on the curve outside the prime-order subgroup (x = 4)" do
      refute Bls.verify_quicknet(1000, "80" <> String.duplicate("00", 46) <> "04")
    end

    test "round 0, a round past 2^64 - 1, and non-integer rounds" do
      refute Bls.verify_quicknet(0, @r1000["signature"])
      refute Bls.verify_quicknet(-1000, @r1000["signature"])
      refute Bls.verify_quicknet(Bls.max_round() + 1, @r1000["signature"])
      refute Bls.verify_quicknet(1000.0, @r1000["signature"])
      refute Bls.verify_quicknet("1000", @r1000["signature"])
      refute Bls.verify_quicknet(nil, @r1000["signature"])
    end

    test "a signature that isn't a string" do
      refute Bls.verify_quicknet(1000, nil)
      refute Bls.verify_quicknet(1000, sig(@r1000))
      refute Bls.verify_quicknet(1000, String.to_charlist(@r1000["signature"]))
    end
  end

  defp sig(%{"signature" => s}), do: Base.decode16!(s, case: :lower)
end

defmodule WallopCore.Drand.BlsTest.NotLoaded do
  # What a Rustler module is when its library didn't load.
  def verify_g1(_pubkey, _round, _sig), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule WallopCore.Drand.BlsTest.AlwaysTrue do
  def verify_g1(_pubkey, _round, _sig), do: true
end

defmodule WallopCore.Drand.BlsTest.AlwaysFalse do
  def verify_g1(_pubkey, _round, _sig), do: false
end
