defmodule WallopCore.Resources.Draw.Validations.DrawAt do
  @moduledoc """
  The protocol-specific lock arguments.

  Runs after `ResolveLockSchema`, so the draw's lock schema is already
  recorded on the changeset.

    * A forecast lock (no lock schema) may not send `draw_at`. Nothing else
      about a forecast lock is checked here.
    * A lock schema "6" lock (observation weather or grid frequency) may
      not send `weather_time`: everything follows from `draw_at`.
    * A schema 6 `draw_at`, when sent, is checked against the recorded
      tag's schedule (`WallopCore.Weather.Schedule` for Land Observations,
      `WallopCore.Frequency.Schedule` for grid frequency): second precision,
      drand quicknet's 3-second grid, the round cap (`within_cap?/2`), and
      the tag's latest lock time (the observation hour minus 46 minutes;
      the window start T minus 60 seconds). A late lock is refused with
      `latest_lock_at`; the draw stays open. A pair with no rules
      (`WallopCore.Entropy.V6Rules.rules/1`) is refused with the unknown
      pair message, never checked against another tag's schedule.

  The lock time is checked again where `locked_at` is signed
  (`SignAndStoreReceipt.v6_lock_time_error/3` and
  `SignAndStoreReceipt.freq_lock_time_error/3`), and by the database.
  Errors are `Ash.Error.Changes.InvalidArgument`, so their `vars` reach the
  JSON:API error's `meta`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument
  alias WallopCore.Entropy.V6Rules
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Resources.Draw.Changes.SignAndStoreReceipt
  alias WallopCore.Resources.Draw.Validations.EntropyRulesAre
  alias WallopCore.Weather.Schedule

  @impl true
  def validate(changeset, _opts, _context) do
    v6? = Ash.Changeset.get_attribute(changeset, :lock_schema_version) == "6"
    draw_at = Ash.Changeset.get_argument(changeset, :draw_at)

    cond do
      not v6? and not is_nil(draw_at) ->
        error(
          :draw_at,
          "is only available to operators on the observation-weather or grid-frequency protocol"
        )

      v6? and not is_nil(Ash.Changeset.get_argument(changeset, :weather_time)) ->
        error(:weather_time, "can't be set for this operator; send draw_at instead")

      v6? and not is_nil(draw_at) ->
        changeset
        |> EntropyRulesAre.pair()
        |> tag_rules()
        |> check(draw_at, DateTime.utc_now())

      true ->
        :ok
    end
  end

  # The schedule module and the late check of the recorded pair's rules.
  # ResolveLockSchema records only known pairs; anything else is refused,
  # never guessed.
  defp tag_rules(pair) do
    case V6Rules.rules(pair) do
      {:ok, :landobs} ->
        {Schedule, &SignAndStoreReceipt.v6_lock_time_error(&1, &2.weather_time)}

      {:ok, :freq} ->
        {FreqSchedule, &SignAndStoreReceipt.freq_lock_time_error(&1, &2.freq_start)}

      :error ->
        {:unknown, pair}
    end
  end

  defp check({:unknown, pair}, _draw_at, _now),
    do:
      error(
        :draw_at,
        V6Rules.unknown_pair_message(pair.lock_schema_version, pair.entropy_composition)
      )

  defp check({schedule, late_error}, draw_at, now) do
    case schedule.schedule(draw_at) do
      {:error, :sub_second} ->
        error(:draw_at, "must have second precision")

      {:error, :not_on_grid} ->
        error(:draw_at, "must fall on drand quicknet's 3-second grid (any whole minute does)")

      {:error, :before_genesis} ->
        error(:draw_at, "is before drand quicknet's first round")

      {:ok, s} ->
        check_schedule(schedule, late_error, s, now)
    end
  end

  defp check_schedule(schedule, late_error, s, now) do
    cond do
      not schedule.within_cap?(now, s.expected_result_at) ->
        error(:draw_at, "must be no more than 7 days (201,600 drand quicknet rounds) from now")

      late = late_error.(now, s) ->
        {:error, late}

      true ->
        :ok
    end
  end

  defp error(field, message),
    do: {:error, InvalidArgument.exception(field: field, message: message)}
end
