defmodule WallopCore.Entropy.DrandClientBlsTest do
  @moduledoc """
  `verify_bls: true`: the beacon must be quicknet's own. Every refusal is
  that relay's `{:error, :invalid_response}`, logged with the relay and the
  kind of failure, never the bytes.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WallopCore.Drand.{Bls, Quicknet}
  alias WallopCore.Entropy.DrandClient

  @fixtures "test/fixtures/drand/quicknet_rounds.json"
            |> File.read!()
            |> Jason.decode!()

  @rounds @fixtures["quicknet"]["rounds"]
  @r1000 Enum.find(@rounds, &(&1["round"] == 1000))
  @r33068212 Enum.find(@rounds, &(&1["round"] == 33_068_212))
  @t33068212 Enum.find(@fixtures["quicknet_t"]["rounds"], &(&1["round"] == 33_068_212))
  @testnet_chain @fixtures["quicknet_t"]["chain_hash"]

  setup do
    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
  end

  defp serve(beacon), do: Req.Test.stub(DrandClient, &Req.Test.json(&1, beacon))

  defp beacon(round, sig_hex),
    do: %{"round" => round, "signature" => sig_hex, "randomness" => randomness(sig_hex)}

  # The randomness a beacon with this signature would carry, so that only
  # the signature check can refuse it.
  defp randomness(sig_hex) do
    case Base.decode16(sig_hex, case: :mixed) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      :error -> String.duplicate("0", 64)
    end
  end

  defp flip_bit(hex, byte_index, bit) do
    <<pre::binary-size(byte_index), b, post::binary>> = Base.decode16!(hex, case: :lower)

    Base.encode16(<<pre::binary, Bitwise.bxor(b, Bitwise.bsl(1, bit)), post::binary>>,
      case: :lower
    )
  end

  defp fetch(round, chain \\ Quicknet.chain_hash()),
    do: DrandClient.fetch_with_failover(chain, round, verify_bls: true)

  describe "real rounds" do
    for r <- @fixtures["quicknet"]["rounds"] do
      @r r
      test "round #{r["round"]} is accepted" do
        serve(Map.take(@r, ~w(round randomness signature)))

        assert {:ok, %{round: round, signature: sig, randomness: rnd}} = fetch(@r["round"])
        assert {round, sig, rnd} == {@r["round"], @r["signature"], @r["randomness"]}
      end
    end
  end

  @r33068212_sig "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

  # {case, requested round, chain, served beacon, logged failure kind}
  @cases [
    {"one bit flipped", 1000, nil, :flip, :bad_signature},
    {"round + 1", 1001, nil, {1001, :r1000}, :bad_signature},
    {"round - 1", 999, nil, {999, :r1000}, :bad_signature},
    {"a quicknet-t signature (another key)", 33_068_212, nil, {33_068_212, :t33068212},
     :bad_signature},
    {"47 bytes", 1000, nil, {1000, {:slice, 94}}, :signature_format},
    {"96 bytes (G2 length)", 1000, nil, {1000, {:double}}, :signature_format},
    {"non-hex", 1000, nil, {1000, String.duplicate("zz", 48)}, :signature_format},
    {"uppercase hex", 1000, nil, {1000, :upper}, :signature_format},
    {"the all-zero point", 1000, nil, {1000, String.duplicate("00", 48)}, :bad_signature},
    {"the compressed identity", 1000, nil, {1000, "c0" <> String.duplicate("00", 47)},
     :bad_signature},
    {"a point not on the curve", 1000, nil, {1000, "80" <> String.duplicate("00", 46) <> "01"},
     :bad_signature},
    {"a point outside the subgroup", 1000, nil,
     {1000, "80" <> String.duplicate("00", 46) <> "04"}, :bad_signature},
    {"round 0", 0, nil, {0, :r1000}, :round},
    {"a round past 2^64 - 1", 0x1_0000_0000_0000_0000, nil, {0x1_0000_0000_0000_0000, :r1000},
     :round},
    {"the wrong chain (quicknet-t's own beacon)", 33_068_212, :testnet, {33_068_212, :t33068212},
     :wrong_chain}
  ]

  describe "refused" do
    for {name, round, chain, served, kind} <- @cases do
      @round round
      @chain chain
      @served served
      @kind kind
      test "#{name}: invalid_response, logged as #{kind}, signature not logged" do
        beacon = served_beacon(@round, @served)
        serve(beacon)
        chain = if @chain == :testnet, do: @testnet_chain, else: Quicknet.chain_hash()

        log = capture_log(fn -> assert {:error, :invalid_response} = fetch(@round, chain) end)

        assert log =~ "relay https://api.drand.sh"
        assert log =~ "failed the BLS check: #{@kind}"
        refute log =~ beacon["signature"]
        refute log =~ String.downcase(beacon["signature"])
      end
    end

    test "mismatched randomness: a valid signature with another round's randomness" do
      serve(%{
        "round" => 1000,
        "signature" => @r1000["signature"],
        "randomness" => @r33068212["randomness"]
      })

      log = capture_log(fn -> assert {:error, :invalid_response} = fetch(1000) end)
      assert log =~ "failed the BLS check: randomness_mismatch"
    end

    test "the stand-in signature tests use for rounds near now is refused for real at its own round's neighbours" do
      # WallopCore.Test.DrandBls accepts it at any round; the real check doesn't.
      refute Bls.verify_quicknet(33_068_213, @r33068212_sig)
      assert Bls.verify_quicknet(33_068_212, @r33068212_sig)
    end
  end

  describe "with on_invalid: :next" do
    test "a forged relay is passed over and the next relay's real beacon is taken" do
      calls = :counters.new(1, [:atomics])

      Req.Test.stub(DrandClient, fn conn ->
        :counters.add(calls, 1, 1)

        sig =
          if :counters.get(calls, 1) == 1,
            do: flip_bit(@r1000["signature"], 47, 0),
            else: @r1000["signature"]

        Req.Test.json(conn, beacon(1000, sig))
      end)

      assert {:ok, %{signature: sig}} =
               DrandClient.fetch_with_failover(Quicknet.chain_hash(), 1000,
                 on_invalid: :next,
                 verify_bls: true
               )

      assert sig == @r1000["signature"]
      assert :counters.get(calls, 1) == 2
    end

    test "every relay forged is all_relays_failed" do
      serve(beacon(1000, flip_bit(@r1000["signature"], 10, 2)))

      assert {:error, {:all_relays_failed, errors}} =
               DrandClient.fetch_with_failover(Quicknet.chain_hash(), 1000,
                 on_invalid: :next,
                 verify_bls: true
               )

      assert length(errors) == length(DrandClient.relays())
      assert Enum.all?(errors, &match?({_relay, :invalid_response}, &1))
    end
  end

  describe "without verify_bls (forecast draws, unchanged)" do
    test "a forged beacon is accepted, as before" do
      forged = beacon(1000, flip_bit(@r1000["signature"], 47, 0))
      serve(forged)

      assert {:ok, %{signature: sig}} =
               DrandClient.fetch_with_failover(Quicknet.chain_hash(), 1000)

      assert sig == forged["signature"]

      assert {:ok, _} =
               DrandClient.fetch_with_failover(Quicknet.chain_hash(), 1000, verify_bls: false)
    end
  end

  defp served_beacon(round, :flip), do: beacon(round, flip_bit(@r1000["signature"], 47, 0))
  defp served_beacon(_round, {round, :r1000}), do: beacon(round, @r1000["signature"])
  defp served_beacon(_round, {round, :t33068212}), do: Map.put(@t33068212, "round", round)

  defp served_beacon(_round, {round, {:slice, n}}),
    do: beacon(round, binary_part(@r1000["signature"], 0, n))

  defp served_beacon(_round, {round, {:double}}),
    do: beacon(round, @r1000["signature"] <> @r1000["signature"])

  defp served_beacon(_round, {round, :upper}),
    do: beacon(round, String.upcase(@r1000["signature"]))

  defp served_beacon(_round, {round, sig}) when is_binary(sig), do: beacon(round, sig)
end
