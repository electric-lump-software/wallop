defmodule WallopCore.Entropy.V6Rules do
  @moduledoc """
  The execution rules of an observation-weather draw, chosen by the draw's
  stored (lock_schema_version, entropy_composition) pair: when it may run,
  which stored reading it uses, how the seed is derived, and the fallback
  reason and station when there is no reading.

  The pair is read from the draw, never from the operator's current flag.
  An unknown pair raises `ArgumentError`; nothing falls through to the
  Land Observations rules. A new tag adds one clause to `rules!/1` and one
  to each function below.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @type rules :: :landobs
  @type reading :: %{
          station: String.t(),
          value: String.t(),
          raw: String.t(),
          observation_time: DateTime.t()
        }

  @doc "The rules for a draw's stored pair. Raises `ArgumentError` for any unknown pair."
  @spec rules!(map()) :: rules()
  def rules!(%{lock_schema_version: schema, entropy_composition: tag}) do
    if schema == "6" and tag == LandObs.tag() do
      :landobs
    else
      raise ArgumentError, unknown_pair_message(schema, tag)
    end
  end

  @doc """
  The refusal for an unknown pair. Same text as the draws guard's, which
  prints a NULL as `<NULL>`.
  """
  @spec unknown_pair_message(term(), term()) :: String.t()
  def unknown_pair_message(schema, tag),
    do:
      "unknown lock_schema_version and entropy_composition pair: " <>
        "(#{schema || "<NULL>"}, #{tag || "<NULL>"})"

  @doc "The end of the reading's fetch window. After it, nothing more can be stored."
  @spec fetch_deadline(rules(), map()) :: DateTime.t()
  def fetch_deadline(:landobs, draw), do: Schedule.fetch_deadline(draw.weather_time)

  @doc "When the draw's drand round publishes: the earliest it may execute."
  @spec drand_pub_time(rules(), map()) :: DateTime.t()
  def drand_pub_time(:landobs, draw), do: Quicknet.pub_time(draw.drand_round)

  @doc "The reading stored for the draw, or nil."
  @spec reading(rules(), map()) :: reading() | nil
  def reading(:landobs, draw) do
    case Observations.for_draw(draw) do
      nil -> nil
      obs -> Map.take(obs, [:station, :value, :raw, :observation_time])
    end
  end

  @doc "The seed and its JCS preimage: with the reading, or drand alone without one."
  @spec seed(rules(), String.t(), String.t(), reading() | nil) :: {binary(), String.t()}
  def seed(:landobs, entry_hash, randomness, nil),
    do: Protocol.compute_seed(entry_hash, randomness)

  def seed(:landobs, entry_hash, randomness, %{value: value}),
    do: Protocol.compute_seed(entry_hash, randomness, value)

  @doc "The fallback reason signed when there is no reading."
  @spec fallback_reason(rules()) :: String.t()
  def fallback_reason(:landobs), do: Protocol.landobs_fallback_reason()

  @doc "The station the execution receipt names when there is no reading: the first one."
  @spec fallback_station(rules()) :: String.t()
  def fallback_station(:landobs), do: Stations.primary().id
end
