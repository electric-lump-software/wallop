defmodule WallopCore.Drand.Quicknet do
  @moduledoc """
  The drand quicknet round grid. Pure: no IO and no clock.

  Round 1 is published at genesis (1692803367, Unix seconds) and each later
  round follows `period/0` seconds after the one before, so
  pub(R) = genesis + (R - 1) * period. Genesis is divisible by 3, so every
  whole minute is a publication time.
  """

  @genesis 1_692_803_367
  @period 3
  @max_round_delta 201_600

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
