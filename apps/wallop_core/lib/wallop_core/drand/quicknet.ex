defmodule WallopCore.Drand.Quicknet do
  @moduledoc """
  The drand quicknet round grid. Pure: no IO and no clock.

  Round 1 is published at genesis (1692803367, Unix seconds) and each later
  round follows `period/0` seconds after the one before, so
  pub(R) = genesis + (R - 1) * period. Genesis is divisible by 3, so every
  whole minute is a publication time.
  """

  @chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
  @genesis 1_692_803_367
  @period 3
  @max_round_delta 201_600

  # Quicknet's group public key: a 96-byte compressed G2 point (scheme
  # bls-unchained-g1-rfc9380). From the chain info at
  # https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info
  # (`public_key`); the wallop_rs verifier pins the same value.
  @public_key Base.decode16!(
                "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c" <>
                  "8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb" <>
                  "5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a",
                case: :lower
              )

  @doc "The quicknet chain hash, as signed into receipts' `drand_chain`."
  @spec chain_hash() :: String.t()
  def chain_hash, do: @chain_hash

  @doc "Quicknet's public key: 96 bytes, a compressed G2 point."
  @spec public_key() :: <<_::768>>
  def public_key, do: @public_key

  @doc "Unix time (seconds) of round 1."
  @spec genesis() :: pos_integer()
  def genesis, do: @genesis

  @doc "Seconds between rounds."
  @spec period() :: pos_integer()
  def period, do: @period

  @doc "The furthest ahead, in rounds, a draw may target: 7 days."
  @spec max_round_delta() :: pos_integer()
  def max_round_delta, do: @max_round_delta

  @doc "The publication time of `round`, with microsecond precision."
  @spec pub_time(pos_integer()) :: DateTime.t()
  def pub_time(round) when is_integer(round) and round >= 1,
    do: DateTime.from_unix!((@genesis + (round - 1) * @period) * 1_000_000, :microsecond)

  @doc """
  The round published exactly at `time`. Refuses times with a sub-second
  part, times between grid points and times before genesis.
  """
  @spec round_at(DateTime.t()) ::
          {:ok, pos_integer()} | {:error, :sub_second | :not_on_grid | :before_genesis}
  def round_at(%DateTime{microsecond: {us, _}}) when us != 0, do: {:error, :sub_second}

  def round_at(%DateTime{} = time) do
    delta = DateTime.to_unix(time) - @genesis

    cond do
      delta < 0 -> {:error, :before_genesis}
      rem(delta, @period) != 0 -> {:error, :not_on_grid}
      true -> {:ok, div(delta, @period) + 1}
    end
  end

  @doc "The earliest round published at or after `time` (round 1 for any time up to genesis)."
  @spec round_at_or_after(DateTime.t()) :: pos_integer()
  def round_at_or_after(%DateTime{} = time) do
    delta_us = DateTime.to_unix(time, :microsecond) - @genesis * 1_000_000
    period_us = @period * 1_000_000

    if delta_us <= 0, do: 1, else: div(delta_us + period_us - 1, period_us) + 1
  end
end
