defmodule WallopCore.Resources.Draw.LockWeatherTimeTest do
  @moduledoc """
  Tests for the optional `weather_time` argument on `Draw.lock`.

  Coverage matrix:

  | # | Concern                                          |
  |---|--------------------------------------------------|
  | 1 | Default behaviour (no arg) preserved             |
  | 2 | Supplied weather_time signed verbatim in receipt |
  | 3 | drand_round derived from weather_time            |
  | 4 | Sub-second precision rejected                    |
  | 5 | < min buffer rejected                            |
  | 6 | > max buffer (7 days) rejected                   |
  | 7 | Default-still-works after the change             |
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  # drand quicknet parameters (must match DeclareEntropy)
  @quicknet_genesis 1_692_803_367
  @quicknet_period 3
  @drand_slack_seconds 30

  describe "default behaviour (no weather_time argument)" do
    test "lock without arg uses the jittered ~3-5 min default" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}], client_ref: Ash.UUID.generate()},
          actor: api_key
        )
        |> Ash.update!()

      before_lock = DateTime.utc_now()

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()

      diff = DateTime.diff(locked.weather_time, before_lock, :second)

      assert diff >= 180 and diff <= 305,
             "expected jittered weather_time in 3-5 min from lock, got #{diff}s"

      # drand_round derived from weather_time, not now.
      assert_drand_round_matches_weather_time(locked.drand_round, locked.weather_time)
    end
  end

  describe "operator-supplied weather_time" do
    test "lock with explicit weather_time 1 hour ahead signs it verbatim" do
      api_key = create_api_key()
      ensure_infrastructure_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}], client_ref: Ash.UUID.generate()},
          actor: api_key
        )
        |> Ash.update!()

      target =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.truncate(:second)

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: target}, actor: api_key)
        |> Ash.update!()

      assert DateTime.compare(locked.weather_time, target) == :eq

      # drand_round must derive from weather_time. Specifically: drand
      # publishes ~30s before the supplied 1h-future moment.
      assert_drand_round_matches_weather_time(locked.drand_round, target)
    end

    test "lock with weather_time 24h ahead — drand round in the far future" do
      api_key = create_api_key()
      ensure_infrastructure_key()

      draw = create_draw_open_with_entries(api_key)

      target =
        DateTime.utc_now()
        |> DateTime.add(86_400, :second)
        |> DateTime.truncate(:second)

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: target}, actor: api_key)
        |> Ash.update!()

      assert DateTime.compare(locked.weather_time, target) == :eq
      assert_drand_round_matches_weather_time(locked.drand_round, target)

      # Sanity: the round number is far ahead of "now". Without the
      # fix, drand_round would be ~current+10 (publishing ~30s from
      # now). With the fix, it publishes ~24h from now.
      now_round =
        div(System.os_time(:second) - @quicknet_genesis, @quicknet_period) + 1

      assert locked.drand_round - now_round > 28_000,
             "drand_round must be far in the future for a 24h weather_time, " <>
               "got delta #{locked.drand_round - now_round} rounds"
    end
  end

  describe "rejections" do
    test "sub-second precision rejected — not silently truncated" do
      api_key = create_api_key()

      draw = create_draw_open_with_entries(api_key)

      target_with_sub_second =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> Map.put(:microsecond, {500_000, 6})

      assert_raise Ash.Error.Invalid, ~r/second precision/, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: target_with_sub_second},
          actor: api_key
        )
        |> Ash.update!()
      end
    end

    test "weather_time < now + 60s rejected" do
      api_key = create_api_key()

      draw = create_draw_open_with_entries(api_key)

      too_near =
        DateTime.utc_now()
        |> DateTime.add(30, :second)
        |> DateTime.truncate(:second)

      assert_raise Ash.Error.Invalid, ~r/at least 60 seconds in the future/, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: too_near}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "weather_time in the past rejected" do
      api_key = create_api_key()

      draw = create_draw_open_with_entries(api_key)

      past =
        DateTime.utc_now()
        |> DateTime.add(-60, :second)
        |> DateTime.truncate(:second)

      assert_raise Ash.Error.Invalid, ~r/at least 60 seconds in the future/, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: past}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "weather_time > now + 7 days rejected" do
      api_key = create_api_key()

      draw = create_draw_open_with_entries(api_key)

      too_far =
        DateTime.utc_now()
        |> DateTime.add(8 * 86_400, :second)
        |> DateTime.truncate(:second)

      assert_raise Ash.Error.Invalid, ~r/within 604800 seconds/, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: too_far}, actor: api_key)
        |> Ash.update!()
      end
    end
  end

  describe "boundary cases" do
    test "weather_time at exactly now + 60s + 5s (safety margin) accepts" do
      api_key = create_api_key()
      ensure_infrastructure_key()

      draw = create_draw_open_with_entries(api_key)

      target =
        DateTime.utc_now()
        |> DateTime.add(65, :second)
        |> DateTime.truncate(:second)

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: target}, actor: api_key)
        |> Ash.update!()

      assert DateTime.compare(locked.weather_time, target) == :eq
    end

    test "weather_time at ~6.9 days accepts (just under cap)" do
      api_key = create_api_key()
      ensure_infrastructure_key()

      draw = create_draw_open_with_entries(api_key)

      # 6.9 days = 596160 seconds; cap is 604800 — well under.
      target =
        DateTime.utc_now()
        |> DateTime.add(596_160, :second)
        |> DateTime.truncate(:second)

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{weather_time: target}, actor: api_key)
        |> Ash.update!()

      assert DateTime.compare(locked.weather_time, target) == :eq
    end
  end

  # -- helpers --

  defp create_draw_open_with_entries(api_key) do
    draw =
      Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
      |> Ash.create!()

    draw
    |> Ash.Changeset.for_update(
      :add_entries,
      %{entries: [%{"weight" => 1}], client_ref: Ash.UUID.generate()},
      actor: api_key
    )
    |> Ash.update!()
  end

  # The drand round must publish at least @drand_slack_seconds before
  # the weather observation time. Verify the relationship holds for
  # every (drand_round, weather_time) pair this test produces.
  defp assert_drand_round_matches_weather_time(drand_round, weather_time) do
    weather_unix = DateTime.to_unix(weather_time, :second)
    publication_unix = @quicknet_genesis + (drand_round - 1) * @quicknet_period
    diff = weather_unix - publication_unix

    assert diff >= @drand_slack_seconds,
           "drand_round #{drand_round} publishes at unix #{publication_unix}, " <>
             "weather_time at #{weather_unix}, diff #{diff}s — " <>
             "MUST be >= @drand_slack_seconds (#{@drand_slack_seconds})"

    # Cross-source binding: drand reveal is BEFORE weather observation.
    # The slack is tight (the round just before would also satisfy >0,
    # but we want at least @drand_slack_seconds).
    assert diff < @drand_slack_seconds + @quicknet_period,
           "drand_round #{drand_round} should be the LATEST round " <>
             "satisfying the slack constraint, got diff #{diff}s " <>
             "(expected #{@drand_slack_seconds} <= diff < #{@drand_slack_seconds + @quicknet_period})"
  end
end
