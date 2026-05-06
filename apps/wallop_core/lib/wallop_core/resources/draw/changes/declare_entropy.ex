defmodule WallopCore.Resources.Draw.Changes.DeclareEntropy do
  @moduledoc """
  Declares entropy sources at lock time.

  This change:

  1. Reads the optional `weather_time` argument (validated by
     `WallopCore.Resources.Draw.Validations.WeatherTime`). If
     supplied, uses it verbatim. If omitted, picks a jittered
     default of 3-5 minutes from now.
  2. Derives `drand_round` as the largest quicknet round whose
     publication time is at least `@drand_slack_seconds` before
     `weather_time`. This binds the drand reveal to the weather
     observation: drand publishes BEFORE the entropy worker fires.
  3. Sets `weather_station` to "middle-wallop" (51.1494, -1.5714).
  4. Sets `drand_chain` to the quicknet chain hash.
  5. Transitions status to `:awaiting_entropy`.
  6. Schedules an EntropyWorker job for `weather_time`.

  ## Cross-source binding invariant

  `drand_round` derivation flows from `weather_time`, never from
  `now`. With operator-supplied `weather_time = now + 24h`, drand
  must publish 30s before that 24h-future moment — not 30s from
  now. Otherwise the drand reveal is observable 24h before the
  weather observation, defeating the cross-source unpredictability
  guarantee that `seed = SHA-256(domsep || entry_hash || drand ||
  weather)` provides. ADR-0012's analogue: lock receipt v5 already
  signs both fields; the derivation just needs to keep them coupled.
  """
  use Ash.Resource.Change

  alias WallopCore.Entropy.{DrandClient, EntropyWorker}

  # drand quicknet parameters (frozen — protocol-level constants).
  @quicknet_genesis 1_692_803_367
  @quicknet_period 3

  # The drand round must publish this many seconds before
  # weather_time so the entropy worker has the round bytes when it
  # fires. ~10 quicknet rounds; matches the historical buffer used
  # before this change.
  @drand_slack_seconds 30

  @weather_station "middle-wallop"

  @impl true
  def change(changeset, _opts, _context) do
    declare_entropy(changeset)
  end

  defp declare_entropy(changeset) do
    changeset
    |> set_entropy_fields()
    |> schedule_entropy_worker()
  end

  defp set_entropy_fields(changeset) do
    if changeset.errors != [] do
      changeset
    else
      weather_time = supplied_or_default_weather_time(changeset)
      drand_round = drand_round_for(weather_time)

      changeset
      |> Ash.Changeset.force_change_attribute(:drand_chain, DrandClient.quicknet_chain_hash())
      |> Ash.Changeset.force_change_attribute(:drand_round, drand_round)
      |> Ash.Changeset.force_change_attribute(:weather_station, @weather_station)
      |> Ash.Changeset.force_change_attribute(:weather_time, weather_time)
      |> Ash.Changeset.force_change_attribute(:status, :awaiting_entropy)
    end
  end

  defp schedule_entropy_worker(changeset) do
    if changeset.errors != [] do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn _changeset, draw ->
        %{draw_id: draw.id}
        |> EntropyWorker.new(scheduled_at: draw.weather_time)
        |> Oban.insert()

        WallopCore.DrawPubSub.broadcast(draw)
        {:ok, draw}
      end)
    end
  end

  # Returns the operator-supplied weather_time if provided (already
  # validated by Validations.WeatherTime), otherwise the jittered
  # default. Truncates to second precision either way; supplied
  # values arrive at second precision per the validator's
  # `microsecond == {0, _}` check.
  defp supplied_or_default_weather_time(changeset) do
    case Ash.Changeset.get_argument(changeset, :weather_time) do
      nil -> jittered_weather_time()
      %DateTime{} = wt -> DateTime.truncate(wt, :second)
    end
  end

  # Pick the largest drand round R such that R publishes at least
  # @drand_slack_seconds before weather_time.
  #
  # Round R publishes at: genesis + (R - 1) * period.
  # We want pub_R <= weather_time - slack.
  # Solving: R <= (weather_time - slack - genesis) / period + 1.
  # Pick the largest integer R satisfying this.
  #
  # `div/2` truncates toward zero, which would misbehave on negative
  # numerators — but the validator's `weather_time > now() + 60s` floor
  # makes weather_unix - slack - genesis comfortably positive in
  # practice (genesis is in the past).
  defp drand_round_for(weather_time) do
    weather_unix = DateTime.to_unix(weather_time, :second)
    div(weather_unix - @drand_slack_seconds - @quicknet_genesis, @quicknet_period) + 1
  end

  defp jittered_weather_time do
    # 3-5 minutes from now (jittered to avoid thundering herd on
    # repeated locks within the same second).
    delay = Enum.random(180..300)

    DateTime.utc_now()
    |> DateTime.add(delay, :second)
    |> DateTime.truncate(:second)
  end
end
