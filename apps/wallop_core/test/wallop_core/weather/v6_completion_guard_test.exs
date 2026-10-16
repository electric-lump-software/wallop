defmodule WallopCore.Weather.V6CompletionGuardTest do
  @moduledoc """
  The draws guard's completion rules for observation-weather draws, now that
  the store exists: complete with exactly the stored reading, or, with nothing
  stored, with the rule's fallback after F; never before pub(R).
  """
  use WallopCore.DataCase, async: false
  import WallopCore.TestHelpers
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @primary Stations.primary().id
  @backup Stations.backup().id
  @stored_only "v6 draw must complete with its stored observation"
  @fallback_only "v6 draw may fall back only after the fetch deadline with nothing stored"

  # A v6 draw in pending_entropy whose stored weather_time is `wt_offset`
  # seconds from now and whose round publishes `pub_offset` seconds from now.
  defp pending(wt_offset, pub_offset, key \\ nil) do
    key = key || elem(create_v6_operator(), 1)
    now = DateTime.utc_now()
    wt = now |> DateTime.add(wt_offset) |> DateTime.truncate(:second)
    round = Quicknet.round_at_or_after(DateTime.add(now, pub_offset))
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    draw
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  # nil when the completion is accepted (and rolled back), else the refusal.
  defp complete(draw, set_sql, params \\ []) do
    {:error, :accepted} =
      Repo.transaction(fn ->
        Repo.query!(
          "UPDATE draws SET status = 'completed', executed_at = $2, #{set_sql} WHERE id = $1",
          [dump(draw.id), NaiveDateTime.utc_now() | params]
        )

        Repo.rollback(:accepted)
      end)

    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  @fallback "weather_fallback_reason = $3"

  defp reading(draw, value \\ "90;1025;85;2432"),
    do: %{value: value, raw: "[]", observation_time: draw.weather_time}

  # Moves the draw's window, and its stored row, an hour back with every
  # trigger off, so "after F" holds while the stored row stays.
  defp shift_window_back!(draw) do
    Repo.query!("SET session_replication_role = replica")

    Repo.query!(
      "UPDATE draws SET weather_time = weather_time - interval '1 hour' WHERE id = $1",
      [dump(draw.id)]
    )

    Repo.query!(
      "UPDATE weather_observations SET observation_time = observation_time - interval '1 hour' WHERE draw_id = $1",
      [dump(draw.id)]
    )

    Repo.query!("RESET session_replication_role")
  end

  test "a v6 draw can't complete with a value that isn't stored, or fall back before F" do
    draw = pending(-5 * 60, -10)

    assert complete(draw, "weather_value = '1;1000;1;1', weather_observation_time = weather_time") ==
             @fallback_only

    assert complete(draw, @fallback, [LandObs.fallback_reason()]) == @fallback_only
  end

  test "an observation is stored, after F, and the draw is completed as a fallback: refused" do
    draw = pending(-(@w - 5 * 60), -10)
    {:ok, obs} = Observations.store(draw.id, @backup, reading(draw))
    shift_window_back!(draw)

    assert complete(draw, @fallback, [LandObs.fallback_reason()]) == @stored_only

    assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
             "91;1025;85;2432"
           ]) == @stored_only

    assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
             obs.value
           ]) ==
             nil
  end

  test "with nothing stored after F, only the rule-based fallback completes" do
    draw = pending(-(@w + 60), -10)
    assert complete(draw, @fallback, ["unreachable"]) == @fallback_only
    assert complete(draw, @fallback, [LandObs.fallback_reason()]) == nil
  end

  test "executed_at >= pub(R): with F < now < pub(R) the draw can't complete" do
    draw = pending(-(@w + 60), 600)

    assert complete(draw, @fallback, [LandObs.fallback_reason()]) ==
             "v6 draw cannot complete before its drand round publishes"
  end

  describe "the backup is used only when nothing was stored for the primary in its window" do
    test "a draw with a primary reading can't take the backup's, by store or by completion" do
      draw = pending(-5 * 60, -10)
      {:ok, primary} = Observations.store(draw.id, @primary, reading(draw, "141;1025;85;2432"))

      # The backup's window is closed now, and a reading is already stored:
      # both refuse it.
      assert {:error, _} = Observations.store(draw.id, @backup, reading(draw))

      shift_window_back!(draw)

      assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
               "90;1025;85;2432"
             ]) == @stored_only

      assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
               primary.value
             ]) == nil
    end

    test "in the backup window a draw with nothing stored takes the backup, never the primary" do
      draw = pending(-(@w - 5 * 60), -10)
      assert {:error, _} = Observations.store(draw.id, @primary, reading(draw))
      assert {:ok, backup} = Observations.store(draw.id, @backup, reading(draw))
      assert {:error, _} = Observations.store(draw.id, @backup, reading(draw))
      assert Observations.for_draw(draw.id).station == @backup

      shift_window_back!(draw)

      assert complete(draw, "weather_value = $3, weather_observation_time = weather_time", [
               backup.value
             ]) == nil
    end
  end
end
