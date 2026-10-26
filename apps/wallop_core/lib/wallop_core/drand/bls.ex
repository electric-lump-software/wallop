defmodule WallopCore.Drand.Bls do
  @moduledoc """
  Checks a drand quicknet beacon's BLS signature, through a Rust NIF that
  wraps the `drand-verify` crate (the crate the wallop_rs verifier uses).

  Quicknet's scheme is `bls-unchained-g1-rfc9380`: the signature is a
  48-byte compressed G1 point over the round number alone, under the
  96-byte G2 public key in `WallopCore.Drand.Quicknet.public_key/0`.

  `verify_quicknet/2` answers true only for a valid signature. Every
  malformed input is false, never a raise: a signature that isn't 96
  lowercase hex characters, a round outside 1..2^64-1, a point that doesn't
  decode, and a NIF call that raises.

  A NIF that isn't loaded is not "false": `self_test!/0`, run at boot,
  raises unless a known round verifies and a forged one doesn't, so the app
  refuses to start without a working check.
  """

  alias WallopCore.Drand.Bls.Native
  alias WallopCore.Drand.Quicknet

  @max_round 0xFFFF_FFFF_FFFF_FFFF

  # Quicknet round 1000, from
  # https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000
  @self_test_round 1000
  @self_test_signature "b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39"

  @doc "The largest round number the check accepts (2^64 - 1)."
  @spec max_round() :: pos_integer()
  def max_round, do: @max_round

  @doc """
  True when `signature_hex` (96 lowercase hex characters) is quicknet's
  signature of `round`. False for anything else.
  """
  @spec verify_quicknet(term(), term()) :: boolean()
  def verify_quicknet(round, signature_hex)
      when is_integer(round) and round >= 1 and round <= @max_round and
             is_binary(signature_hex) and byte_size(signature_hex) == 96 do
    with true <- lowercase_hex?(signature_hex),
         {:ok, sig} <- Base.decode16(signature_hex, case: :lower) do
      Native.verify_g1(Quicknet.public_key(), round, sig) === true
    else
      _ -> false
    end
  rescue
    _ in [ErlangError, ArgumentError] -> false
  end

  def verify_quicknet(_round, _signature_hex), do: false

  @doc """
  Raises unless the NIF is loaded and gives the right answers: a real
  quicknet round verifies, and the same signature for the next round
  doesn't. Called by `WallopCore.Application` before anything starts.
  """
  @spec self_test!(module()) :: :ok
  def self_test!(native \\ Native) do
    loaded? = Code.ensure_loaded?(native) and function_exported?(native, :verify_g1, 3)
    good = loaded? and answer(native, @self_test_round) === true
    forged = loaded? and answer(native, @self_test_round + 1) === false

    if good and forged do
      :ok
    else
      raise "the drand BLS NIF is not working (loaded: #{loaded?}, known round verifies: " <>
              "#{good}, forged round refused: #{forged}); refusing to start"
    end
  end

  # A NIF that isn't loaded raises here; that is a wrong answer, not a crash.
  defp answer(native, round) do
    native.verify_g1(Quicknet.public_key(), round, sig())
  rescue
    _ in [ErlangError, ArgumentError, UndefinedFunctionError] -> :raised
  end

  defp sig, do: Base.decode16!(@self_test_signature, case: :lower)

  defp lowercase_hex?(s), do: s =~ ~r/\A[0-9a-f]{96}\z/
end
