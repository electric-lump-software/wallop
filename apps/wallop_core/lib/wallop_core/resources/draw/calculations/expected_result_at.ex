defmodule WallopCore.Resources.Draw.Calculations.ExpectedResultAt do
  @moduledoc """
  When a v6 draw's result is due: pub(drand_round) for a draw locked under
  lock schema "6" with the Land Observations tag or the grid-frequency tag.
  Nil for every draw without a lock schema.

  Any other combination is a row the draws guard should never have stored.
  This is a public read path, so it never raises: it returns nil and logs a
  warning naming only the redacted draw id. It never falls through to a
  tag's rule.
  """
  use Ash.Resource.Calculation

  require Logger

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Log
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Weather.Schedule

  @landobs LandObs.tag()
  @freq Freq.tag()

  @impl true
  def load(_query, _opts, _context),
    do: [:id, :lock_schema_version, :entropy_composition, :drand_round]

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &expected_result_at/1)

  defp expected_result_at(%{lock_schema_version: nil, entropy_composition: nil}), do: nil

  defp expected_result_at(%{
         lock_schema_version: "6",
         entropy_composition: @landobs,
         drand_round: round
       })
       when is_integer(round) and round >= 1,
       do: Schedule.pub_time(round)

  defp expected_result_at(%{
         lock_schema_version: "6",
         entropy_composition: @freq,
         drand_round: round
       })
       when is_integer(round) and round >= 1,
       do: Quicknet.pub_time(round)

  defp expected_result_at(record) do
    Logger.warning(
      "ExpectedResultAt: inconsistent lock schema on draw #{Log.redact_id(Map.get(record, :id))}"
    )

    nil
  end
end
