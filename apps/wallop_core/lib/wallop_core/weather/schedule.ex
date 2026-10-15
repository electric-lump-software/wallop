defmodule WallopCore.Weather.Schedule do
  @moduledoc """
  Timing for draws on the observation weather protocol (lock schema 6,
  execution schema 5). Pure: no IO and no clock; callers pass the times.

  The operator picks `draw_at` on drand quicknet's 3-second grid (every
  whole minute is on it, because genesis 1692803367 is divisible by 3).
  Everything else follows:

    * round R is the round with pub(R) == draw_at;
    * weather_time is the latest whole UTC hour h with h + W + 60s <= pub(R);
    * the fetch deadline F is weather_time + W; the backup cutover is F - 10 min;
    * a lock is allowed only while now <= weather_time - 46 min.

  W, the 46-minute offset and the 10-minute cutover are frozen by the
  `drand-quicknet+metoffice-landobs-v1` tag. Changing any of them needs a
  new tag.
  """

  @quicknet_genesis 1_692_803_367
  @quicknet_period 3

  # W, the observation fetch window. Provisional: set to the measured p99
  # Land Observations publication latency + 10 minutes (capped at 90) before
  # release. Mirrored by the SQL function wallop_v6_fetch_window().
  @fetch_window_seconds 40 * 60
  @backup_cutover_before_deadline_seconds 10 * 60
  @lock_offset_seconds 46 * 60
  @observation_slack_seconds 60
  @max_round_delta 201_600
  @first_poll_after_weather_time_seconds 5 * 60
  @poll_interval_seconds 60
  @execution_delay_seconds 5
  @default_margin_seconds 30

  @type schedule :: %{
          draw_at: DateTime.t(),
          round: pos_integer(),
          weather_time: DateTime.t(),
          backup_cutover: DateTime.t(),
          fetch_deadline: DateTime.t(),
          latest_lock_at: DateTime.t(),
          expected_result_at: DateTime.t()
        }

  def fetch_window_seconds, do: @fetch_window_seconds
  def lock_offset_seconds, do: @lock_offset_seconds
  def poll_interval_seconds, do: @poll_interval_seconds
  def first_poll_after_weather_time_seconds, do: @first_poll_after_weather_time_seconds
  def execution_delay_seconds, do: @execution_delay_seconds

  @doc "The full schedule for a draw time. See the moduledoc for the rules."
  @spec v6_schedule(DateTime.t()) ::
          {:ok, schedule()} | {:error, :sub_second | :not_on_grid | :before_genesis}
  def v6_schedule(%DateTime{microsecond: {us, _}}) when us != 0, do: {:error, :sub_second}

  def v6_schedule(%DateTime{} = draw_at) do
    delta = DateTime.to_unix(draw_at) - @quicknet_genesis

    cond do
      delta < 0 -> {:error, :before_genesis}
      rem(delta, @quicknet_period) != 0 -> {:error, :not_on_grid}
      true -> {:ok, schedule_for_round(div(delta, @quicknet_period) + 1)}
    end
  end

  defp schedule_for_round(round) do
    wt = weather_time_for_round(round)
    pub = pub_time(round)

    %{
      draw_at: pub,
      round: round,
      weather_time: wt,
      backup_cutover: backup_cutover(wt),
      fetch_deadline: fetch_deadline(wt),
      latest_lock_at: latest_lock_at(wt),
      expected_result_at: pub
    }
  end

  @spec pub_time(pos_integer()) :: DateTime.t()
  def pub_time(round) when is_integer(round) and round >= 1,
    do: from_unix(@quicknet_genesis + (round - 1) * @quicknet_period)

  @spec weather_time_for_round(pos_integer()) :: DateTime.t()
  def weather_time_for_round(round) do
    latest =
      @quicknet_genesis + (round - 1) * @quicknet_period - @fetch_window_seconds -
        @observation_slack_seconds

    from_unix(latest - Integer.mod(latest, 3600))
  end

  def fetch_deadline(wt), do: DateTime.add(wt, @fetch_window_seconds)

  def backup_cutover(wt),
    do: DateTime.add(wt, @fetch_window_seconds - @backup_cutover_before_deadline_seconds)

  def latest_lock_at(wt), do: DateTime.add(wt, -@lock_offset_seconds)

  @spec lock_allowed?(DateTime.t(), DateTime.t()) :: boolean()
  def lock_allowed?(locked_at, wt), do: DateTime.compare(locked_at, latest_lock_at(wt)) != :gt

  @spec within_cap?(DateTime.t(), DateTime.t()) :: boolean()
  def within_cap?(now, expected_result_at),
    do: DateTime.diff(expected_result_at, now) <= @max_round_delta * @quicknet_period

  @doc """
  The draw time used when the operator sends none: the earliest grid point
  whose weather_time is at least 46 minutes (plus a 30-second margin for the
  lock's own work) after `now`.
  """
  @spec default_draw_at(DateTime.t()) :: DateTime.t()
  def default_draw_at(%DateTime{} = now) do
    earliest = DateTime.to_unix(now) + @lock_offset_seconds + @default_margin_seconds
    hour = earliest + Integer.mod(-earliest, 3600)
    target = hour + @fetch_window_seconds + @observation_slack_seconds
    from_unix(target + Integer.mod(-(target - @quicknet_genesis), @quicknet_period))
  end

  defp from_unix(seconds), do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)
end
