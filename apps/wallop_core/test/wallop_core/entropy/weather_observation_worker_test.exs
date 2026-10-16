defmodule WallopCore.Entropy.WeatherObservationWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo
  use ExUnitProperties

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers

  alias WallopCore.Entropy.{LandObsClient, WeatherObservationWorker}
  alias WallopCore.Repo
  alias WallopCore.Test.WindowedLandObsClient
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @primary Stations.primary().id
  @backup Stations.backup().id
  @poll [:wallop_core, :weather, :poll]
  @stored [:wallop_core, :weather, :stored]
  @store_refused [:wallop_core, :weather, :store_refused]
  @poll_error [:wallop_core, :weather, :poll_error]

  setup do
    Application.put_env(:wallop_core, LandObsClient, plug: {Req.Test, LandObsClient})
    previous_key = Application.get_env(:wallop_core, :met_office_obs_api_key)
    Application.put_env(:wallop_core, :met_office_obs_api_key, "test-placeholder")

    on_exit(fn ->
      Application.delete_env(:wallop_core, LandObsClient)

      if previous_key,
        do: Application.put_env(:wallop_core, :met_office_obs_api_key, previous_key),
        else: Application.delete_env(:wallop_core, :met_office_obs_api_key)
    end)
  end

  # The database clock can't be set, so the draws' weather_time is placed
  # `offset` seconds from now and is not a whole hour; the test client
  # (WindowedLandObsClient) fetches the whole hour at or before it with the
  # real client. Whole-hour cases are below, where the clock allows them.
  defp v6_draws(offset, n) do
    wt = DateTime.utc_now() |> DateTime.add(offset) |> DateTime.truncate(:second)
    {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
    {_op, key} = create_v6_operator()
    draws = for _ <- 1..n, do: put_v6_awaiting!(open_draw_with_entries(key), wt, s.round)
    {wt, draws}
  end

  # Serves each station's body (nil: a 503), and tells the test which
  # stations were asked.
  defp stub_stations(%{"gcnfur" => primary, "gcrem9" => backup}) do
    test = self()

    Req.Test.stub(LandObsClient, fn conn ->
      geohash = conn.request_path |> String.split("/") |> List.last()
      send(test, {:fetched, geohash})
      body = if geohash == "gcnfur", do: primary, else: backup
      Plug.Conn.send_resp(conn, if(body, do: 200, else: 503), body || "{}")
    end)
  end

  defp row(wt, t) do
    stamp = Calendar.strftime(WindowedLandObsClient.floor_hour(wt), "%Y-%m-%dT%H:%M:%SZ")

    ~s([{"datetime": "#{stamp}", "temperature": #{t}, "mslp": 1025, "humidity": 85, "visibility": 24320.0}])
  end

  defp run(wt),
    do: perform_job(WeatherObservationWorker, %{weather_time: DateTime.to_iso8601(wt)})

  defp attach(events), do: :telemetry_test.attach_event_handlers(self(), events)

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  describe "storing" do
    test "stores the primary reading once for the hour, shared by every pending draw" do
      {wt, draws} = v6_draws(-6 * 60, 3)
      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      ref = attach([@poll, @stored])

      assert :ok = run(wt)

      for d <- draws do
        assert %{station: @primary, value: "141;1025;85;2432"} = Observations.for_draw(d.id)
      end

      assert Observations.pending_v6_draw_ids(wt) == []

      for station <- [@primary, @backup] do
        assert_receive {@poll, ^ref, %{count: 1},
                        %{station: ^station, weather_time: ^wt, ok?: true, error: nil}}
      end

      assert_receive {@stored, ^ref, %{count: 1}, %{station: @primary, weather_time: ^wt}}
      refute_receive {@stored, ^ref, _, _}
    end

    test "keeps polling while the primary row is missing, before the cutover" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      stub_stations(%{"gcnfur" => "[]", "gcrem9" => row(wt, 9.0)})
      ref = attach([@poll])

      assert {:snooze, s} = run(wt)
      assert s == Schedule.poll_interval_seconds()
      assert Observations.for_draw(d.id) == nil
      assert Observations.for_hour(wt) == nil

      assert_receive {@poll, ^ref, _, %{station: @primary, ok?: false, error: :missing_hour}}
      # The backup is polled (and measured), but not stored in the primary window.
      assert_receive {@poll, ^ref, _, %{station: @backup, ok?: true}}
    end

    test "after the cutover only the backup can be stored" do
      {wt, [d]} = v6_draws(-(@w - 5 * 60), 1)
      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      assert :ok = run(wt)
      assert %{station: @backup, value: "90;1025;85;2432"} = Observations.for_draw(d.id)
    end

    test "the last poll is made before F, not after it" do
      {wt, _} = v6_draws(-(@w - 20), 1)
      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => nil})
      assert {:snooze, s} = run(wt)
      assert s <= 15
    end

    test "after F it stops without fetching or storing" do
      {wt, [d]} = v6_draws(-(@w + 60), 1)
      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      assert :ok = run(wt)
      assert Observations.for_draw(d.id) == nil
      refute_received {:fetched, _}
    end

    test "an hour already stored is done: no fetch, no second store" do
      {wt, [d]} = v6_draws(-6 * 60, 1)

      {:ok, _} =
        Observations.store(@primary, %{value: "150;1025;85;2432", raw: "[]", observation_time: wt})

      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      assert :ok = run(wt)
      assert %{value: "150;1025;85;2432"} = Observations.for_draw(d.id)
      refute_received {:fetched, _}
    end

    test "a store refused because another run stored the hour first counts as done" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      ref = attach([@stored, @store_refused])

      # The other run stores while this one is fetching.
      Req.Test.stub(LandObsClient, fn conn ->
        if String.ends_with?(conn.request_path, "gcnfur") do
          {:ok, _} =
            Observations.store(@primary, %{
              value: "150;1025;85;2432",
              raw: "[]",
              observation_time: wt
            })
        end

        Plug.Conn.send_resp(conn, 200, row(wt, 14.11))
      end)

      log = capture_log(fn -> assert :ok = run(wt) end)

      assert %{value: "150;1025;85;2432"} = Observations.for_draw(d.id)
      refute_received {@stored, ^ref, _, _}
      refute_received {@store_refused, ^ref, _, _}
      refute log =~ "refused"
    end

    test "any other refused store is reported and the job polls again" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      ref = attach([@store_refused])

      # The store refuses to run inside a caller's transaction.
      capture_log(fn ->
        assert {:ok, {:snooze, _}} = Repo.transaction(fn -> run(wt) end)
      end)

      assert_receive {@store_refused, ^ref, %{count: 1},
                      %{station: @primary, weather_time: ^wt, reason: :nested_transaction}}

      assert Observations.for_draw(d.id) == nil
    end

    test "nothing pending for the hour: done, without fetching" do
      wt = DateTime.utc_now() |> DateTime.add(-6 * 60) |> DateTime.truncate(:second)
      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      assert :ok = run(wt)
      refute_received {:fetched, _}
    end

    test "a forecast draw of the hour is never fetched for or stored" do
      wt = DateTime.utc_now() |> DateTime.add(-6 * 60) |> DateTime.truncate(:second)
      forecast = create_draw(create_api_key())

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET weather_time = $2 WHERE id = $1", [
          Ecto.UUID.dump!(forecast.id),
          DateTime.to_naive(wt)
        ])
      end)

      stub_stations(%{"gcnfur" => row(wt, 14.11), "gcrem9" => row(wt, 9.0)})
      assert :ok = run(wt)
      assert Observations.for_hour(wt) == nil
      refute_received {:fetched, _}
    end
  end

  describe "whole hours" do
    test "before the first poll (weather_time + 5 min) it waits, without fetching" do
      next_hour = DateTime.add(WindowedLandObsClient.floor_hour(DateTime.utc_now()), 3600)
      {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
      {_op, key} = create_v6_operator()
      put_v6_awaiting!(open_draw_with_entries(key), next_hour, s.round)
      stub_stations(%{"gcnfur" => "[]", "gcrem9" => "[]"})

      assert {:snooze, wait} = run(next_hour)
      expected = DateTime.diff(DateTime.add(next_hour, 5 * 60), DateTime.utc_now())
      assert abs(wait - expected) <= 2
      refute_received {:fetched, _}
    end

    test "the test client is the real client for a whole hour" do
      hour = ~U[2026-10-14 01:00:00Z]

      Req.Test.stub(LandObsClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, row(hour, 14.11))
      end)

      for station <- Stations.all() do
        assert WindowedLandObsClient.fetch_hour(station.geohash, hour) ==
                 LandObsClient.fetch_hour(station.geohash, hour)
      end
    end
  end

  describe "errors" do
    test "a missing API key stores nothing, keeps polling, and says so in telemetry" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      ref = attach([@poll])
      Application.delete_env(:wallop_core, :met_office_obs_api_key)

      assert {:snooze, _} = run(wt)
      assert Observations.for_draw(d.id) == nil

      for station <- [@primary, @backup] do
        assert_receive {@poll, ^ref, %{count: 1},
                        %{station: ^station, ok?: false, error: :no_api_key}}
      end
    end

    test "an exception during a poll snoozes until F instead of failing the job" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      ref = attach([@poll_error, @poll])
      # A non-string base URL makes the client raise inside the poll.
      Application.put_env(:wallop_core, LandObsClient, base_url: 123)

      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)
      assert Observations.for_draw(d.id) == nil

      # Counted per station, in both events.
      for station <- [@primary, @backup] do
        assert_receive {@poll_error, ^ref, %{count: 1},
                        %{weather_time: ^wt, station: ^station, kind: :error}}

        assert_receive {@poll, ^ref, %{count: 1},
                        %{
                          station: ^station,
                          weather_time: ^wt,
                          ok?: false,
                          error: {:raised, :error}
                        }}
      end

      assert log =~ "ArgumentError"

      {late_wt, _} = v6_draws(-(@w + 60), 1)
      assert :ok = run(late_wt)
    end

    test "when the database clock can't be read it snoozes, even well past F on the BEAM clock" do
      # F passed long ago: stopping on the BEAM clock would return :ok here.
      {wt, _} = v6_draws(-(@w + 3600), 1)
      ref = attach([@poll_error])

      # Every query in an aborted transaction fails, so the run's first
      # database-clock read raises and so does the read after the failure.
      log =
        capture_log(fn ->
          result =
            Repo.transaction(fn ->
              {:error, _} = Repo.query("SELECT 1/0")
              Repo.rollback(run(wt))
            end)

          send(self(), {:result, result})
        end)

      assert_received {:result, {:error, {:snooze, s}}}
      assert s == Schedule.poll_interval_seconds()
      assert log =~ "Postgrex.Error"

      assert_receive {@poll_error, ^ref, %{count: 1},
                      %{weather_time: ^wt, station: nil, kind: :error}}
    end

    test "logs and telemetry carry no body and no key" do
      {wt, _} = v6_draws(-6 * 60, 1)
      key = "obs-key-SHOULD-NOT-APPEAR"
      Application.put_env(:wallop_core, :met_office_obs_api_key, key)
      ref = attach([@poll, @poll_error])
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      Req.Test.stub(LandObsClient, fn conn ->
        Plug.Conn.send_resp(conn, 503, ~s({"detail": "BODY-SHOULD-NOT-APPEAR"}))
      end)

      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)

      assert_receive {@poll, ^ref, _, %{error: {:unexpected_status, 503}} = m1}
      assert_receive {@poll, ^ref, _, %{error: {:unexpected_status, 503}} = m2}

      for text <- [log, inspect(m1), inspect(m2)] do
        refute text =~ "SHOULD-NOT-APPEAR"
      end
    end

    test "invalid job arguments cancel the job" do
      assert {:cancel, :invalid_weather_time} =
               perform_job(WeatherObservationWorker, %{weather_time: "not a time"})

      assert {:cancel, :invalid_weather_time} =
               perform_job(WeatherObservationWorker, %{weather_time: "2026-10-14T19:00:00+01:00"})
    end
  end

  describe "the job" do
    test "one job per hour, however many draws lock for it" do
      iso = "2026-10-14T19:00:00Z"
      {:ok, a} = Oban.insert(WeatherObservationWorker.new(%{weather_time: iso}))
      {:ok, b} = Oban.insert(WeatherObservationWorker.new(%{weather_time: iso}))
      assert b.conflict?
      assert a.id == b.id
    end

    test "new_for_hour writes one canonical hour and schedules the first poll" do
      wt = ~U[2026-10-14 19:00:00Z]
      precise = ~U[2026-10-14 19:00:00.000000Z]

      {:ok, a} = Oban.insert(WeatherObservationWorker.new_for_hour(wt))
      {:ok, b} = Oban.insert(WeatherObservationWorker.new_for_hour(precise))

      {:ok, c} =
        Oban.insert(WeatherObservationWorker.new(%{weather_time: "2026-10-14T19:00:00Z"}))

      assert a.args == %{weather_time: "2026-10-14T19:00:00Z"}
      assert a.queue == "weather"
      assert DateTime.compare(a.scheduled_at, ~U[2026-10-14 19:05:00Z]) == :eq
      assert b.conflict? and b.id == a.id
      assert c.conflict? and c.id == a.id

      {:ok, other} = Oban.insert(WeatherObservationWorker.new_for_hour(~U[2026-10-14 20:00:00Z]))
      refute other.conflict?
    end

    test "new_for_hour takes whole UTC hours only" do
      for bad <- [
            ~U[2026-10-14 19:00:01Z],
            ~U[2026-10-14 19:30:00Z],
            ~U[2026-10-14 19:00:00.000001Z],
            %{~U[2026-10-14 19:00:00Z] | time_zone: "Europe/London"}
          ] do
        assert_raise ArgumentError, ~r/whole UTC hour/, fn ->
          WeatherObservationWorker.new_for_hour(bad)
        end
      end
    end

    test "the job timeout is at most 30 s and fits inside the poll interval" do
      timeout = WeatherObservationWorker.timeout(%Oban.Job{})
      assert timeout <= 30_000
      assert timeout < Schedule.poll_interval_seconds() * 1000
    end

    test "the weather queue runs on the wallop service" do
      queues = Application.fetch_env!(:wallop_core, Oban) |> Keyword.fetch!(:queues)
      assert queues[:weather] >= 2
    end
  end

  describe "the station follows from the database clock alone" do
    @wt ~N[2026-10-14 19:00:00.000000]

    defp sql_allowed(station, now) do
      %{rows: [[v]]} =
        Repo.query!("SELECT wallop_landobs_observation_allowed($1, $2, $3)", [station, @wt, now])

      v
    end

    defp expected_from_sql(now) do
      case {sql_allowed(@primary, now), sql_allowed(@backup, now)} do
        {true, false} -> {:ok, @primary}
        {false, true} -> {:ok, @backup}
        {false, false} -> :neither
      end
    end

    defp worker_choice(now) do
      case WeatherObservationWorker.station_for(
             DateTime.from_naive!(now, "Etc/UTC"),
             DateTime.from_naive!(@wt, "Etc/UTC")
           ) do
        {:ok, station} -> {:ok, station.id}
        _ -> :neither
      end
    end

    test "at every window boundary, the worker's station is the one the store allows" do
      cutover = (@w - 10 * 60) * 1_000_000
      deadline = @w * 1_000_000

      for offset <- [
            -1,
            0,
            1,
            cutover - 1,
            cutover,
            cutover + 1,
            deadline - 1,
            deadline,
            deadline + 1
          ] do
        now = NaiveDateTime.add(@wt, offset, :microsecond)
        assert worker_choice(now) == expected_from_sql(now), "at #{offset}us"
      end

      wt = DateTime.from_naive!(@wt, "Etc/UTC")

      assert WeatherObservationWorker.station_for(DateTime.add(wt, -1, :microsecond), wt) ==
               :not_yet

      assert WeatherObservationWorker.station_for(
               DateTime.add(wt, @w * 1_000_000 + 1, :microsecond),
               wt
             ) == :closed
    end

    property "and at any instant around the window" do
      check all(offset <- integer(-3_600_000_000..(2 * @w * 1_000_000)), max_runs: 300) do
        now = NaiveDateTime.add(@wt, offset, :microsecond)
        assert worker_choice(now) == expected_from_sql(now)
      end
    end
  end
end
