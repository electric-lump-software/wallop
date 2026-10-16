defmodule WallopCore.Resources.Draw.Validations.DrawAt do
  @moduledoc """
  The protocol-specific lock arguments.

  Runs after `ResolveLockSchema`, so the draw's lock schema is already
  recorded on the changeset.

    * A forecast lock (no lock schema) may not send `draw_at`. Nothing else
      about a forecast lock is checked here.
    * An observation-weather lock (lock schema "6") may not send
      `weather_time`: the observation hour follows from `draw_at`.
    * An observation-weather `draw_at`, when sent, must have second
      precision, sit on drand quicknet's 3-second grid, publish within the
      round cap (`Schedule.within_cap?/2`), and leave the lock no later than
      the observation hour minus 46 minutes. A late lock is refused with
      `latest_lock_at`; the draw stays open.

  The lock time is checked again where `locked_at` is signed
  (`SignAndStoreReceipt.v6_lock_time_error/2`), and by the database.
  Errors are `Ash.Error.Changes.InvalidArgument`, so their `vars` reach the
  JSON:API error's `meta`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidArgument
  alias WallopCore.Resources.Draw.Changes.SignAndStoreReceipt
  alias WallopCore.Weather.Schedule

  @impl true
  def validate(changeset, _opts, _context) do
    v6? = Ash.Changeset.get_attribute(changeset, :lock_schema_version) == "6"
    draw_at = Ash.Changeset.get_argument(changeset, :draw_at)

    cond do
      not v6? and not is_nil(draw_at) ->
        error(:draw_at, "is only available to operators on the observation weather protocol")

      v6? and not is_nil(Ash.Changeset.get_argument(changeset, :weather_time)) ->
        error(:weather_time, "can't be set for this operator; send draw_at instead")

      v6? and not is_nil(draw_at) ->
        check(draw_at, DateTime.utc_now())

      true ->
        :ok
    end
  end

  defp check(draw_at, now) do
    case Schedule.schedule(draw_at) do
      {:error, :sub_second} ->
        error(:draw_at, "must have second precision")

      {:error, :not_on_grid} ->
        error(:draw_at, "must fall on drand quicknet's 3-second grid (any whole minute does)")

      {:error, :before_genesis} ->
        error(:draw_at, "is before drand quicknet's first round")

      {:ok, s} ->
        check_schedule(s, now)
    end
  end

  defp check_schedule(s, now) do
    cond do
      not Schedule.within_cap?(now, s.expected_result_at) ->
        error(:draw_at, "must be within 7 days (201,600 drand quicknet rounds)")

      late = SignAndStoreReceipt.v6_lock_time_error(now, s.weather_time) ->
        {:error, late}

      true ->
        :ok
    end
  end

  defp error(field, message),
    do: {:error, InvalidArgument.exception(field: field, message: message)}
end
