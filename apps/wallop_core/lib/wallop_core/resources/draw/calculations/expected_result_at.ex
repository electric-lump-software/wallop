defmodule WallopCore.Resources.Draw.Calculations.ExpectedResultAt do
  @moduledoc """
  When an observation-weather draw's result is due: pub(drand_round) for a
  draw locked under (lock schema "6", the Land Observations tag). Nil for
  every draw without a lock schema. Any other pair raises, rather than fall
  through to a tag's rule; the draws guard never stores one.
  """
  use Ash.Resource.Calculation

  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Weather.Schedule

  @impl true
  def load(_query, _opts, _context),
    do: [:lock_schema_version, :entropy_composition, :drand_round]

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &expected_result_at/1)

  defp expected_result_at(%{lock_schema_version: nil}), do: nil

  defp expected_result_at(%{
         lock_schema_version: "6",
         entropy_composition: tag,
         drand_round: round
       })
       when is_integer(round) do
    if tag == LandObs.tag(),
      do: Schedule.pub_time(round),
      else:
        raise(ArgumentError, "no expected_result_at rule for entropy_composition #{inspect(tag)}")
  end

  defp expected_result_at(%{lock_schema_version: schema, entropy_composition: tag}) do
    raise ArgumentError,
          "no expected_result_at rule for (#{inspect(schema)}, #{inspect(tag)})"
  end
end
