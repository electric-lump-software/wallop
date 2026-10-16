defmodule WallopCore.Weather.ObservationStoreTest do
  use WallopCore.DataCase, async: false
  import WallopCore.TestHelpers
  alias WallopCore.Repo
  alias WallopCore.Resources.{Draw, WeatherObservation}
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @primary Stations.primary().id
  @backup Stations.backup().id

  defp round do
    {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
    s.round
  end

  # weather_time need not be a whole hour here: the trigger compares against
  # the draw's own weather_time, so tests can place "now" anywhere in the window.
  defp v6_draw_with_weather_time(offset_seconds_from_now) do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(offset_seconds_from_now) |> DateTime.truncate(:second)
    put_v6_awaiting!(open_draw_with_entries(key), wt, round())
  end

  defp reading(draw, value \\ "141;1025;85;2432"),
    do: %{value: value, raw: "[]", observation_time: draw.weather_time}

  defp refused(result) do
    assert {:error, error} = result
    Exception.message(error)
  end

  test "primary is stored inside the window, only once per draw" do
    draw = v6_draw_with_weather_time(-5 * 60)
    assert {:ok, obs} = Observations.store(draw.id, @primary, reading(draw))
    assert obs.stored_at
    assert abs(DateTime.diff(obs.stored_at, Observations.db_now(), :second)) < 5

    assert refused(Observations.store(draw.id, @primary, reading(draw))) =~
             "an observation is already stored for this draw"

    assert refused(Observations.store(draw.id, @backup, reading(draw))) =~
             "an observation is already stored for this draw"
  end

  test "the trigger uses the window: primary refused before weather_time, backup refused early" do
    early = v6_draw_with_weather_time(60)

    assert refused(Observations.store(early.id, @primary, reading(early))) =~
             "#{@primary} observation outside its window"

    in_primary = v6_draw_with_weather_time(-5 * 60)

    assert refused(Observations.store(in_primary.id, @backup, reading(in_primary))) =~
             "#{@backup} observation outside its window"

    in_backup = v6_draw_with_weather_time(-(@w - 5 * 60))

    assert refused(Observations.store(in_backup.id, @primary, reading(in_backup))) =~
             "#{@primary} observation outside its window"

    assert {:ok, %{station: @backup}} =
             Observations.store(in_backup.id, @backup, reading(in_backup))

    after_deadline = v6_draw_with_weather_time(-(@w + 30))

    assert refused(Observations.store(after_deadline.id, @backup, reading(after_deadline))) =~
             "#{@backup} observation outside its window"
  end

  test "one value per (station, hour): a second draw of the hour can't store a different value" do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-5 * 60) |> DateTime.truncate(:second)
    r = round()
    a = put_v6_awaiting!(open_draw_with_entries(key), wt, r)
    b = put_v6_awaiting!(open_draw_with_entries(key), wt, r)
    c = put_v6_awaiting!(open_draw_with_entries(key), wt, r)

    assert {:ok, _} = Observations.store(a.id, @primary, reading(a))

    assert refused(Observations.store(b.id, @primary, reading(b, "142;1025;85;2432"))) =~
             "a different value is already stored for this station and hour"

    assert {:ok, _} = Observations.store(c.id, @primary, reading(c))
  end

  test "observation_time must equal weather_time; values must match the grammar and bounds; stations are closed" do
    draw = v6_draw_with_weather_time(-5 * 60)

    assert refused(
             Observations.store(draw.id, @primary, %{
               reading(draw)
               | observation_time: DateTime.add(draw.weather_time, 3600)
             })
           ) =~ "observation_time must equal the draw's weather_time"

    for bad <- ["102500", "601;1025;85;2432", "141;1025;85;10001", "-0;1025;85;2432"] do
      assert refused(Observations.store(draw.id, @primary, reading(draw, bad))) =~
               "does not match the Land Observations value grammar and bounds",
             bad
    end

    # The insert trigger refuses an unknown station first (it has no window);
    # the CHECK refuses it too, even with every trigger off.
    assert refused(Observations.store(draw.id, "wmo-99999", reading(draw))) =~
             "wmo-99999 observation outside its window"

    assert_raise Postgrex.Error, ~r/weather_observations_station/, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!(
          """
          INSERT INTO weather_observations (id, draw_id, station, observation_time, value, raw)
          VALUES (gen_random_uuid(), $1, 'wmo-99999', $2, '141;1025;85;2432', '[]')
          """,
          [Ecto.UUID.dump!(draw.id), DateTime.to_naive(draw.weather_time)]
        )
      end)
    end

    # Nothing above was stored: the draw still takes its reading.
    assert {:ok, _} = Observations.store(draw.id, @primary, reading(draw))
  end

  test "a draw that isn't waiting for entropy, or is under an unknown tag, gets no observation" do
    draw = v6_draw_with_weather_time(-5 * 60)

    Repo.query!("SET session_replication_role = replica")

    Repo.query!("UPDATE draws SET status = 'completed' WHERE id = $1", [
      Ecto.UUID.dump!(draw.id)
    ])

    Repo.query!("RESET session_replication_role")

    assert refused(Observations.store(draw.id, @primary, reading(draw))) =~
             "draw is not waiting for entropy"

    other = v6_draw_with_weather_time(-5 * 60)

    Repo.query!("SET session_replication_role = replica")

    Repo.query!(
      "UPDATE draws SET entropy_composition = 'drand-quicknet+other-v1' WHERE id = $1",
      [
        Ecto.UUID.dump!(other.id)
      ]
    )

    Repo.query!("RESET session_replication_role")

    assert refused(Observations.store(other.id, @primary, reading(other))) =~
             "no observation rules for entropy_composition drand-quicknet+other-v1"
  end

  test "a forecast draw can never get an observation" do
    draw = create_draw(create_api_key())

    assert refused(
             Observations.store(draw.id, @primary, %{
               value: "1;1000;1;1",
               raw: "[]",
               observation_time: draw.weather_time || DateTime.utc_now()
             })
           ) =~ "weather observations are stored only for v6 draws"
  end

  test "rows are write-once: no UPDATE, DELETE or TRUNCATE" do
    draw = v6_draw_with_weather_time(-5 * 60)
    {:ok, _} = Observations.store(draw.id, @primary, reading(draw))
    id = Ecto.UUID.dump!(draw.id)

    assert db_refused?(
             "UPDATE weather_observations SET value = '1;1000;1;1' WHERE draw_id = $1",
             [id]
           )

    assert db_refused?("DELETE FROM weather_observations WHERE draw_id = $1", [id])

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
    assert {:ok, _} = Observations.store(draw.id, @primary, reading(draw))

    early = v6_draw_with_weather_time(60)
    assert {:error, _} = Observations.store(early.id, @primary, reading(early))
  end

  test "the store transaction can't be left open: it sets short timeouts" do
    draw = v6_draw_with_weather_time(-5 * 60)

    {:ok, {statement, idle}} =
      Repo.transaction(fn ->
        {:ok, _} = Observations.store(draw.id, @primary, reading(draw))

        {Repo.query!("SHOW statement_timeout").rows,
         Repo.query!("SHOW idle_in_transaction_session_timeout").rows}
      end)

    assert statement == [["5s"]]
    assert idle == [["10s"]]
  end

  test "actors can't read or store observations" do
    draw = v6_draw_with_weather_time(-5 * 60)
    api_key = create_api_key()

    params = Map.merge(reading(draw), %{draw_id: draw.id, station: @primary})
    changeset = Ash.Changeset.for_create(WeatherObservation, :store, params, actor: api_key)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.create(changeset)

    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(WeatherObservation, actor: api_key)
  end

  describe "lookups" do
    test "for_draw/1 and db_now/0" do
      draw = v6_draw_with_weather_time(-5 * 60)
      assert Observations.for_draw(draw.id) == nil
      {:ok, obs} = Observations.store(draw.id, @primary, reading(draw))
      assert Observations.for_draw(draw.id).id == obs.id
      assert abs(DateTime.diff(Observations.db_now(), DateTime.utc_now(), :second)) < 5
    end

    test "pending_v6_draw_ids/1 lists waiting v6 draws of the hour with nothing stored" do
      {_op, key} = create_v6_operator()
      wt = DateTime.utc_now() |> DateTime.add(-5 * 60) |> DateTime.truncate(:second)
      r = round()
      [a, b, c] = for _ <- 1..3, do: put_v6_awaiting!(open_draw_with_entries(key), wt, r)
      other_hour = put_v6_awaiting!(open_draw_with_entries(key), DateTime.add(wt, -3600), r)

      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
        Ecto.UUID.dump!(c.id)
      ])

      {:ok, _} = Observations.store(a.id, @primary, reading(a))

      ids = Observations.pending_v6_draw_ids(wt)
      assert Enum.sort(ids) == Enum.sort([b.id, c.id])
      refute other_hour.id in ids

      # A forecast draw is never listed.
      forecast = create_draw(create_api_key())
      refute forecast.id in Observations.pending_v6_draw_ids(wt)
      assert %Draw{} = Ash.get!(Draw, forecast.id, authorize?: false)
    end
  end
end
