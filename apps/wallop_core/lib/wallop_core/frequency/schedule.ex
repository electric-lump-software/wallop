defmodule WallopCore.Frequency.Schedule do
  @moduledoc """
  Timing for draws on the grid-frequency entropy tag
  `drand-quicknet+elexon-freq-v1` (lock schema 6, execution schema 5).
  Pure: no IO and no clock; callers pass the times.

  The operator picks `draw_at` on drand quicknet's 3-second grid. Then:

    * round R is the round with pub(R) == draw_at;
    * the window start T = floor15(pub(R) - 105 s - W_freq - M), where
      floor15 rounds down to a whole multiple of 15 seconds of Unix time;
    * the readings are T, T + 15 s, ..., T + 105 s (8 readings);
    * they may be stored only within [T + 105 s, F], F = T + 105 s + W_freq,
      checked when the insert runs and again when it commits;
    * F <= pub(R) - M always, so the store is settled, and committed, at
      least M seconds before the drand round exists;
    * a lock is allowed only while locked_at <= T - 60 s.

  W_freq, M, the 60-second lock gap and the 8 readings 15 seconds apart are
  frozen by the tag. Changing any of them needs a new tag.
  """

  alias WallopCore.Drand.Quicknet

  # W_freq, the frequency fetch window. Provisional: before vectors freeze
  # it is set to max(observed batch publication latency, measured from
  # T + 105 s) + 40 s (two poll intervals), capped at 240 s. Mirrored by the
  # SQL function wallop_freq_fetch_window() and the verifier's W_FREQ_SECS.
  @fetch_window_seconds 240
  # M, the margin between the fetch deadline F and pub(R): F <= pub(R) - M.
  # With the commit-time check it only has to cover clock skew between the
  # database and drand. Mirrored by wallop_freq_margin() and MARGIN_SECS.
  @margin_seconds 15
  @readings 8
  @spacing_seconds 15
  @span_seconds (@readings - 1) * @spacing_seconds
  @lock_gap_seconds 60
  @first_poll_after_store_from_seconds 30
  @poll_interval_seconds 20
  @execution_delay_seconds 5
  @default_margin_seconds 30

  @type schedule :: %{
          draw_at: DateTime.t(),
          round: pos_integer(),
          freq_start: DateTime.t(),
          store_from: DateTime.t(),
          fetch_deadline: DateTime.t(),
          latest_lock_at: DateTime.t(),
          expected_result_at: DateTime.t()
        }

  @spec fetch_window_seconds() :: pos_integer()
  def fetch_window_seconds, do: @fetch_window_seconds
  @spec margin_seconds() :: pos_integer()
  def margin_seconds, do: @margin_seconds
  @spec readings() :: pos_integer()
  def readings, do: @readings
  @spec spacing_seconds() :: pos_integer()
  def spacing_seconds, do: @spacing_seconds
  @spec span_seconds() :: pos_integer()
  def span_seconds, do: @span_seconds
  @spec lock_gap_seconds() :: pos_integer()
  def lock_gap_seconds, do: @lock_gap_seconds
  @spec first_poll_after_store_from_seconds() :: pos_integer()
  def first_poll_after_store_from_seconds, do: @first_poll_after_store_from_seconds
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: @poll_interval_seconds
  @spec execution_delay_seconds() :: pos_integer()
  def execution_delay_seconds, do: @execution_delay_seconds

  @doc "The full schedule for a draw time. See the moduledoc for the rules."
  @spec schedule(DateTime.t()) ::
          {:ok, schedule()} | {:error, :sub_second | :not_on_grid | :before_genesis}
  def schedule(%DateTime{} = draw_at) do
    with {:ok, round} <- Quicknet.round_at(draw_at), do: {:ok, schedule_for_round(round)}
  end

  defp schedule_for_round(round) do
    t = freq_start_for_round(round)
    pub = pub_time(round)

    %{
      draw_at: pub,
      round: round,
      freq_start: t,
      store_from: store_from(t),
      fetch_deadline: fetch_deadline(t),
      latest_lock_at: latest_lock_at(t),
      expected_result_at: pub
    }
  end

  @doc "The publication time of `round`. See `WallopCore.Drand.Quicknet.pub_time/1`."
  @spec pub_time(pos_integer()) :: DateTime.t()
  defdelegate pub_time(round), to: Quicknet

  @doc "T = floor15(pub(round) - 105 s - W_freq - M)."
  @spec freq_start_for_round(pos_integer()) :: DateTime.t()
  def freq_start_for_round(round) when is_integer(round) and round >= 1 do
    latest =
      DateTime.to_unix(Quicknet.pub_time(round)) - @span_seconds - @fetch_window_seconds -
        @margin_seconds

    from_unix(latest - Integer.mod(latest, @spacing_seconds))
  end

  @doc "The 8 reading times T, T + 15 s, ..., T + 105 s."
  @spec reading_times(DateTime.t()) :: [DateTime.t()]
  def reading_times(%DateTime{} = t),
    do: Enum.map(0..(@readings - 1), &DateTime.add(t, &1 * @spacing_seconds))

  @spec store_from(DateTime.t()) :: DateTime.t()
  def store_from(t), do: DateTime.add(t, @span_seconds)

  @spec fetch_deadline(DateTime.t()) :: DateTime.t()
  def fetch_deadline(t), do: DateTime.add(t, @span_seconds + @fetch_window_seconds)

  @spec latest_lock_at(DateTime.t()) :: DateTime.t()
  def latest_lock_at(t), do: DateTime.add(t, -@lock_gap_seconds)

  @spec lock_allowed?(DateTime.t(), DateTime.t()) :: boolean()
  def lock_allowed?(locked_at, t), do: DateTime.compare(locked_at, latest_lock_at(t)) != :gt

  @spec within_cap?(DateTime.t(), DateTime.t()) :: boolean()
  def within_cap?(now, expected_result_at),
    do: DateTime.diff(expected_result_at, now) <= Quicknet.max_round_delta() * Quicknet.period()

  @doc """
  The draw time used when the operator sends none: the earliest grid point
  whose window starts at least 60 s (the lock gap) plus a 30 s margin
  after `now`.
  """
  @spec default_draw_at(DateTime.t()) :: DateTime.t()
  def default_draw_at(%DateTime{} = now) do
    # The 30-second margin is load-bearing: to_unix/1 drops the microseconds
    # of `now`, and the lock itself happens a little after `now`.
    earliest = DateTime.to_unix(now) + @lock_gap_seconds + @default_margin_seconds
    t = earliest + Integer.mod(-earliest, @spacing_seconds)
    target = from_unix(t + @span_seconds + @fetch_window_seconds + @margin_seconds)
    Quicknet.pub_time(Quicknet.round_at_or_after(target))
  end

  defp from_unix(seconds), do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)
end
