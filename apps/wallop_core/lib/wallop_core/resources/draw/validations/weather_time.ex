defmodule WallopCore.Resources.Draw.Validations.WeatherTime do
  @moduledoc """
  Validates the optional `weather_time` argument on the `Draw.lock`
  action.

  When supplied, `weather_time` is committed to the lock receipt and
  determines when the entropy worker fires. Letting the operator
  pick this value gives them flexibility to commit the entry set well
  before the actual draw execution time (eg. a sale that closes 24h
  before the reveal). When omitted, `DeclareEntropy` falls back to
  its jittered default of ~3-5 minutes from lock-time.

  ## Conditions

  - **Second precision only.** Sub-second values are rejected, not
    silently truncated. What the operator supplies is what gets
    signed in the lock receipt; rounding behind their back is a
    surprise vector.

  - **Minimum buffer.** `weather_time > now() + 60 seconds`. Gives
    the entropy worker scheduling slack and ensures the derived
    drand round publishes before the worker fires.

  - **Maximum buffer.** `weather_time < now() + #{60 * 60 * 24 * 7} seconds`
    (~7 days, equivalent to `MAX_ROUND_DELTA = 201_600` quicknet
    rounds at 3s/round). Operational cap — drand chain re-key risk
    accumulates over long horizons.
  """
  use Ash.Resource.Validation

  @minimum_buffer_seconds 60

  # The cap is expressed in drand rounds (not days) because the
  # operational risk it bounds is drand chain re-key, which is round-
  # counted not day-counted. The seconds form below is a derived
  # convenience for the time-bounds check against `now()`.
  @max_round_delta 201_600
  @quicknet_period 3
  @max_buffer_seconds @max_round_delta * @quicknet_period

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :weather_time) do
      nil ->
        :ok

      %DateTime{} = weather_time ->
        validate_weather_time(weather_time)

      other ->
        {:error, field: :weather_time, message: "must be a UTC datetime, got: #{inspect(other)}"}
    end
  end

  defp validate_weather_time(weather_time) do
    cond do
      not second_precision?(weather_time) ->
        {:error,
         field: :weather_time,
         message:
           "must have second precision (no sub-second component); " <>
             "the supplied value is signed verbatim into the lock receipt"}

      DateTime.diff(weather_time, DateTime.utc_now(), :second) < @minimum_buffer_seconds ->
        {:error,
         field: :weather_time,
         message: "must be at least #{@minimum_buffer_seconds} seconds in the future"}

      DateTime.diff(weather_time, DateTime.utc_now(), :second) > @max_buffer_seconds ->
        {:error,
         field: :weather_time,
         message:
           "must be within #{@max_buffer_seconds} seconds (~7 days; cap is " <>
             "expressed as MAX_ROUND_DELTA = 201,600 drand quicknet rounds)"}

      true ->
        :ok
    end
  end

  # `:utc_datetime_usec` preserves microseconds. The DateTime
  # `microsecond` field is `{value, precision}`. Accept iff the
  # value component is zero — the operator may declare any
  # precision tag (`.0`, `.000`, `.000000`) so long as there's no
  # actual sub-second component. Reject any non-zero value.
  defp second_precision?(%DateTime{microsecond: {0, _precision}}), do: true
  defp second_precision?(%DateTime{}), do: false
end
