defmodule WallopCore.Weather.ObservationStoreTest do
  use WallopCore.DataCase, async: false
  import WallopCore.TestHelpers
  alias WallopCore.Repo
  alias WallopCore.Resources.{Draw, WeatherObservation}
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @primary Stations.primary().id
  @backup Stations.backup().id
  @value "141;1025;85;2432"
  @already "an observation is already stored for this hour"
  @no_draw "no observation-weather draw is waiting for this hour"

  defp round do
    {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
    s.round
  end

  defp wt_at(offset_seconds),
    do: DateTime.utc_now() |> DateTime.add(offset_seconds) |> DateTime.truncate(:second)

  # weather_time need not be a whole hour here: the trigger keys on the
  # stored weather_time, so tests can place "now" anywhere in the window.
  defp v6_draw_with_weather_time(offset_seconds_from_now, key \\ nil) do
    key = key || elem(create_v6_operator(), 1)
    put_v6_awaiting!(open_draw_with_entries(key), wt_at(offset_seconds_from_now), round())
  end

  defp reading(draw, value \\ @value),
    do: %{value: value, raw: "[]", observation_time: draw.weather_time}

  defp store(station, draw, value \\ @value),
    do: Observations.store(station, reading(draw, value))

  defp refused(result) do
    assert {:error, error} = result
    Exception.message(error)
  end

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  defp raw_insert!(station, wt, value \\ @value) do
    Repo.query!(
      """
      INSERT INTO weather_observations (id, station, observation_time, value, raw)
      VALUES (gen_random_uuid(), $1, $2, $3, '[]')
      """,
      [station, DateTime.to_naive(wt), value]
    )
  end

  test "the primary is stored inside its window, once per hour" do
    draw = v6_draw_with_weather_time(-5 * 60)
    assert {:ok, obs} = store(@primary, draw)
    assert obs.observation_time == draw.weather_time
    assert abs(DateTime.diff(obs.stored_at, Observations.db_now(), :second)) < 5

    assert refused(store(@primary, draw)) =~ @already
    assert refused(store(@primary, draw, "142;1025;85;2432")) =~ @already
    assert {:error, _} = store(@backup, draw)
  end

  test "every draw of the hour reads the hour's one reading" do
    {_op, key} = create_v6_operator()
    wt = wt_at(-5 * 60)
    r = round()
    draws = for _ <- 1..3, do: put_v6_awaiting!(open_draw_with_entries(key), wt, r)

    assert {:ok, obs} = store(@primary, hd(draws))

    for draw <- draws do
      assert Observations.for_draw(draw).id == obs.id
      assert Observations.for_draw(draw.id).id == obs.id
      assert refused(store(@primary, draw, "142;1025;85;2432")) =~ @already
    end

    assert Observations.for_hour(wt).id == obs.id
  end

  test "the trigger uses the window: primary refused before weather_time, backup refused early" do
    early = v6_draw_with_weather_time(60)
    assert refused(store(@primary, early)) =~ "#{@primary} observation outside its window"

    in_primary = v6_draw_with_weather_time(-5 * 60)
    assert refused(store(@backup, in_primary)) =~ "#{@backup} observation outside its window"

    in_backup = v6_draw_with_weather_time(-(@w - 5 * 60))
    assert refused(store(@primary, in_backup)) =~ "#{@primary} observation outside its window"
    assert {:ok, %{station: @backup}} = store(@backup, in_backup)

    after_deadline = v6_draw_with_weather_time(-(@w + 30))

    assert refused(store(@backup, after_deadline)) =~
             "#{@backup} observation outside its window"
  end

  test "a backup can't be stored once the hour has a primary row" do
    draw = v6_draw_with_weather_time(-(@w - 5 * 60))
    # A primary row for the hour, as if stored in the primary window.
    with_triggers_off(fn -> raw_insert!(@primary, draw.weather_time) end)

    assert refused(store(@backup, draw)) =~ @already
    assert Observations.for_draw(draw).station == @primary
  end

  test "values must match the grammar and bounds; stations are closed; the hour needs a waiting draw" do
    draw = v6_draw_with_weather_time(-5 * 60)

    assert refused(
             Observations.store(@primary, %{
               reading(draw)
               | observation_time: DateTime.add(draw.weather_time, 3600)
             })
           ) =~ @no_draw

    for bad <- ["102500", "601;1025;85;2432", "141;1025;85;10001", "-0;1025;85;2432"] do
      assert refused(store(@primary, draw, bad)) =~
               "does not match the Land Observations value grammar and bounds",
             bad
    end

    # The insert trigger refuses an unknown station first (it has no window);
    # the CHECK refuses it too, even with every trigger off.
    assert refused(store("wmo-99999", draw)) =~ "wmo-99999 observation outside its window"

    assert_raise Postgrex.Error, ~r/weather_observations_station/, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")
        raw_insert!("wmo-99999", draw.weather_time)
      end)
    end

    # Nothing above was stored: the hour still takes its reading.
    assert {:ok, _} = store(@primary, draw)
  end

  test "an hour whose draws aren't waiting, or are under an unknown tag, gets no observation" do
    done = v6_draw_with_weather_time(-5 * 60)

    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET status = 'completed' WHERE id = $1", [
        Ecto.UUID.dump!(done.id)
      ])
    end)

    assert refused(store(@primary, done)) =~ @no_draw

    other = v6_draw_with_weather_time(-4 * 60)

    with_triggers_off(fn ->
      Repo.query!(
        "UPDATE draws SET entropy_composition = 'drand-quicknet+other-v1' WHERE id = $1",
        [Ecto.UUID.dump!(other.id)]
      )
    end)

    assert refused(store(@primary, other)) =~ @no_draw
  end

  describe "forecast draws are untouched" do
    test "an hour with only a forecast draw can't get an observation" do
      draw = create_draw(create_api_key())
      wt = wt_at(-5 * 60)

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET weather_time = $2 WHERE id = $1", [
          Ecto.UUID.dump!(draw.id),
          DateTime.to_naive(wt)
        ])
      end)

      assert refused(
               Observations.store(@primary, %{value: @value, raw: "[]", observation_time: wt})
             ) =~
               @no_draw
    end

    test "a forecast draw never reads an observation, even one stored for its hour" do
      v6 = v6_draw_with_weather_time(-5 * 60)
      {:ok, _} = store(@primary, v6)
      forecast = create_draw(create_api_key())

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET weather_time = $2 WHERE id = $1", [
          Ecto.UUID.dump!(forecast.id),
          DateTime.to_naive(v6.weather_time)
        ])
      end)

      forecast = Ash.get!(Draw, forecast.id, authorize?: false)
      assert forecast.weather_time == v6.weather_time
      assert Observations.for_draw(forecast) == nil
      assert Observations.for_draw(forecast.id) == nil
      refute forecast.id in Observations.pending_draw_ids(v6.weather_time)
    end
  end

  test "rows are write-once: no UPDATE, DELETE or TRUNCATE" do
    draw = v6_draw_with_weather_time(-5 * 60)
    {:ok, _} = store(@primary, draw)
    wt = DateTime.to_naive(draw.weather_time)

    assert db_refused?(
             "UPDATE weather_observations SET value = '1;1000;1;1' WHERE observation_time = $1",
             [wt]
           )

    assert db_refused?("DELETE FROM weather_observations WHERE observation_time = $1", [wt])

    # The sandbox never commits, so the deferred commit-time check is still
    # queued; run it now (before F, so it passes) and TRUNCATE then meets the
    # write-once trigger, as it would after a real commit.
    Repo.query!("SET CONSTRAINTS weather_observations_commit_deadline IMMEDIATE")

    assert_raise Postgrex.Error, ~r/weather observations are write-once/, fn ->
      Repo.query!("TRUNCATE weather_observations")
    end
  end

  test "the window does not depend on the session time zone" do
    Repo.query!("SET LOCAL TIME ZONE 'Asia/Kolkata'")
    draw = v6_draw_with_weather_time(-5 * 60)
    assert {:ok, _} = store(@primary, draw)

    early = v6_draw_with_weather_time(60)
    assert {:error, _} = store(@primary, early)
  end

  describe "the store runs in its own transaction" do
    test "it refuses to run inside a caller's transaction" do
      draw = v6_draw_with_weather_time(-5 * 60)

      assert Repo.transaction(fn -> store(@primary, draw) end) ==
               {:ok, {:error, :nested_transaction}}

      assert Observations.for_draw(draw) == nil
    end

    test "the sandbox's own transaction doesn't count as the caller's" do
      refute Repo.in_transaction?()
      assert {:ok, _} = store(@primary, v6_draw_with_weather_time(-5 * 60))
    end

    test "it sets short statement and idle-in-transaction timeouts" do
      # In the sandbox the store's transaction is a savepoint, so its SET
      # LOCAL settings are still visible after it returns.
      assert {:ok, _} = store(@primary, v6_draw_with_weather_time(-5 * 60))
      assert Repo.query!("SHOW statement_timeout").rows == [["5s"]]
      assert Repo.query!("SHOW idle_in_transaction_session_timeout").rows == [["5s"]]
    end
  end

  test "actors can't read or store observations" do
    draw = v6_draw_with_weather_time(-5 * 60)
    api_key = create_api_key()
    params = Map.put(reading(draw), :station, @primary)
    changeset = Ash.Changeset.for_create(WeatherObservation, :store, params, actor: api_key)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.create(changeset)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(WeatherObservation, actor: api_key)
  end

  describe "lookups" do
    test "for_draw/1, for_hour/1 and db_now/0" do
      draw = v6_draw_with_weather_time(-5 * 60)
      assert Observations.for_draw(draw) == nil
      assert Observations.for_hour(draw.weather_time) == nil
      {:ok, obs} = store(@primary, draw)
      assert Observations.for_draw(draw).id == obs.id
      assert Observations.for_hour(draw.weather_time).id == obs.id
      assert abs(DateTime.diff(Observations.db_now(), DateTime.utc_now(), :second)) < 5
    end

    test "pending_draw_ids/1 lists the hour's waiting v6 draws until the hour has its reading" do
      {_op, key} = create_v6_operator()
      wt = wt_at(-5 * 60)
      r = round()
      [a, b] = for _ <- 1..2, do: put_v6_awaiting!(open_draw_with_entries(key), wt, r)
      other_hour = put_v6_awaiting!(open_draw_with_entries(key), DateTime.add(wt, -3600), r)

      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
        Ecto.UUID.dump!(b.id)
      ])

      ids = Observations.pending_draw_ids(wt)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      refute other_hour.id in ids

      {:ok, _} = store(@primary, a)
      assert Observations.pending_draw_ids(wt) == []
    end
  end
end
