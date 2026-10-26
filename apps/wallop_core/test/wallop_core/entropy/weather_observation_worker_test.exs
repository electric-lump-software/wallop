defmodule WallopCore.Entropy.WeatherObservationWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo
  use ExUnitProperties

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers

  alias WallopCore.Entropy.{LandObsClient, WeatherObservationWorker}
  alias WallopCore.Repo
  alias WallopCore.Test.WindowedLandObsClient
  alias WallopCore.Weather.{LandObsBudget, Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @primary Stations.primary().id
  @poll [:wallop_core, :weather, :poll]
  @stored [:wallop_core, :weather, :stored]
  @store_refused [:wallop_core, :weather, :store_refused]
  @poll_error [:wallop_core, :weather, :poll_error]
  @cap_reached [:wallop_core, :weather, :cap_reached]

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

  # Serves Middle Wallop's body (nil: a 503), and tells the test which
  # geohash was asked.
  defp stub_primary(body) do
    test = self()

    Req.Test.stub(LandObsClient, fn conn ->
      geohash = conn.request_path |> String.split("/") |> List.last()
      send(test, {:fetched, geohash})
      Plug.Conn.send_resp(conn, if(body, do: 200, else: 503), body || "{}")
    end)
  end

  defp row(wt, t) do
    stamp = Calendar.strftime(WindowedLandObsClient.floor_hour(wt), "%Y-%m-%dT%H:%M:%SZ")

    ~s([{"datetime": "#{stamp}", "temperature": #{t}, "mslp": 1012, "humidity": 67, "visibility": 34500.0}])
  end

  defp run(wt),
    do: perform_job(WeatherObservationWorker, %{weather_time: DateTime.to_iso8601(wt)})

  defp calls_today do
    %{rows: rows} =
      Repo.query!(
        "SELECT calls FROM land_obs_call_counts WHERE utc_day = (statement_timestamp() AT TIME ZONE 'UTC')::date"
      )

    case rows do
      [[calls]] -> calls
      [] -> 0
    end
  end

  defp set_cap(cap) do
    previous = Application.get_env(:wallop_core, :land_obs_daily_cap)
    Application.put_env(:wallop_core, :land_obs_daily_cap, cap)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wallop_core, :land_obs_daily_cap, previous),
        else: Application.delete_env(:wallop_core, :land_obs_daily_cap)
    end)
  end

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
      stub_primary(row(wt, 12.34))
      ref = attach([@poll, @stored])

      assert :ok = run(wt)

      for d <- draws do
        assert %{station: @primary, value: "123;1012;67;3450"} = Observations.for_draw(d.id)
      end

      assert Observations.pending_draw_ids(wt) == []

      assert_receive {@poll, ^ref, %{count: 1},
                      %{station: @primary, weather_time: ^wt, ok?: true, error: nil}}

      refute_receive {@poll, ^ref, _, _}
      assert_receive {@stored, ^ref, %{count: 1}, %{station: @primary, weather_time: ^wt}}
      refute_receive {@stored, ^ref, _, _}
    end

    test "keeps polling while the reading is missing" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      stub_primary("[]")
      ref = attach([@poll])

      assert {:snooze, s} = run(wt)
      assert s == Schedule.poll_interval_seconds()
      assert Observations.for_draw(d.id) == nil
      assert Observations.for_hour(wt) == nil

      assert_receive {@poll, ^ref, _, %{station: @primary, ok?: false, error: :missing_hour}}
      refute_receive {@poll, ^ref, _, _}
    end

    test "each poll fetches Middle Wallop once, so an hour costs at most 26 calls" do
      {wt, [d]} = v6_draws(-(@w - 5 * 60), 1)
      stub_primary(row(wt, 12.34))
      assert :ok = run(wt)
      assert %{station: @primary, value: "123;1012;67;3450"} = Observations.for_draw(d.id)

      assert_receive {:fetched, "gcnfur"}
      refute_receive {:fetched, _}, 50

      assert div(
               Schedule.fetch_window_seconds() - Schedule.first_poll_after_weather_time_seconds(),
               Schedule.poll_interval_seconds()
             ) + 1 == 26
    end

    test "the last poll is made before F, not after it" do
      {wt, _} = v6_draws(-(@w - 20), 1)
      stub_primary(nil)
      assert {:snooze, s} = run(wt)
      assert s <= 15
    end

    test "after F it stops without fetching or storing" do
      {wt, [d]} = v6_draws(-(@w + 60), 1)
      stub_primary(row(wt, 12.34))
      assert :ok = run(wt)
      assert Observations.for_draw(d.id) == nil
      refute_received {:fetched, _}
    end

    test "an hour already stored is done: no fetch, no second store" do
      {wt, [d]} = v6_draws(-6 * 60, 1)

      {:ok, _} =
        Observations.store(@primary, %{value: "150;1012;67;3450", raw: "[]", observation_time: wt})

      stub_primary(row(wt, 12.34))
      assert :ok = run(wt)
      assert %{value: "150;1012;67;3450"} = Observations.for_draw(d.id)
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
              value: "150;1012;67;3450",
              raw: "[]",
              observation_time: wt
            })
        end

        Plug.Conn.send_resp(conn, 200, row(wt, 12.34))
      end)

      log = capture_log(fn -> assert :ok = run(wt) end)

      assert %{value: "150;1012;67;3450"} = Observations.for_draw(d.id)
      refute_received {@stored, ^ref, _, _}
      refute_received {@store_refused, ^ref, _, _}
      refute log =~ "refused"
    end

    test "any other refused store is reported and the job polls again" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      stub_primary(row(wt, 12.34))
      ref = attach([@store_refused])

      # A trigger that refuses every insert, for this test's transaction only.
      Repo.query!("""
      CREATE FUNCTION test_refuse_observation() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'refused for the test'; END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER test_refuse_observation BEFORE INSERT ON weather_observations
        FOR EACH ROW EXECUTE FUNCTION test_refuse_observation()
      """)

      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)

      assert_receive {@store_refused, ^ref, %{count: 1},
                      %{station: @primary, weather_time: ^wt, reason: :refused}}

      assert log =~ "refused (refused)"
      assert Observations.for_draw(d.id) == nil
    end

    test "nothing pending for the hour: done, without fetching" do
      wt = DateTime.utc_now() |> DateTime.add(-6 * 60) |> DateTime.truncate(:second)
      stub_primary(row(wt, 12.34))
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

      stub_primary(row(wt, 12.34))
      assert :ok = run(wt)
      assert Observations.for_hour(wt) == nil
      refute_received {:fetched, _}
    end
  end

  describe "the daily cap" do
    test "each poll reserves one call on today's counter, before fetching" do
      {wt, _} = v6_draws(-6 * 60, 1)
      stub_primary("[]")
      before = calls_today()

      capture_log(fn -> assert {:snooze, _} = run(wt) end)
      assert_receive {:fetched, "gcnfur"}
      assert calls_today() == before + 1
    end

    test "at the cap: no call, a :daily_cap poll error, and a snooze past F" do
      set_cap(1)
      {wt, [d]} = v6_draws(-6 * 60, 1)
      stub_primary(row(wt, 12.34))
      {:ok, 1} = LandObsBudget.reserve()
      ref = attach([@poll, @cap_reached, @stored])

      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)

      refute_received {:fetched, _}
      assert Observations.for_draw(d.id) == nil
      refute_received {@stored, ^ref, _, _}

      assert_received {@poll, ^ref, %{count: 1},
                       %{station: @primary, weather_time: ^wt, ok?: false, error: :daily_cap}}

      assert_received {@cap_reached, ^ref, %{count: 1}, %{weather_time: ^wt, cap: 1}}
      assert log =~ "daily cap of 1 Land Observations calls reached"
      assert log =~ "failed (:daily_cap)"
    end

    test "the snooze lands just after F, where the job ends" do
      set_cap(1)
      {:ok, 1} = LandObsBudget.reserve()
      {wt, _} = v6_draws(-6 * 60, 1)
      stub_primary("[]")

      capture_log(fn ->
        {:snooze, s} = run(wt)
        until_f = DateTime.diff(Schedule.fetch_deadline(wt), DateTime.utc_now())
        # One second past F, give or take the test's own running time.
        assert s in (until_f + 1 - 2)..(until_f + 1 + 2)
        assert s > Schedule.poll_interval_seconds()
      end)

      {late_wt, _} = v6_draws(-(@w + 1), 1)
      assert :ok = run(late_wt)
      refute_received {:fetched, _}
    end

    test "one error log a day, however many calls are refused; telemetry for each" do
      set_cap(1)
      {:ok, 1} = LandObsBudget.reserve()
      {wt, _} = v6_draws(-6 * 60, 1)
      ref = attach([@cap_reached])

      log =
        capture_log(fn ->
          for _ <- 1..3, do: assert({:snooze, _} = run(wt))
        end)

      refute_received {:fetched, _}
      assert length(Regex.scan(~r/daily cap of 1 Land Observations calls reached/, log)) == 1

      for _ <- 1..3, do: assert_received({@cap_reached, ^ref, %{count: 1}, %{cap: 1}})
      refute_received {@cap_reached, ^ref, _, _}
      assert calls_today() == 4
    end

    test "a counter that can't be written means no call" do
      {wt, _} = v6_draws(-6 * 60, 1)
      stub_primary(row(wt, 12.34))
      ref = attach([@poll_error])

      Repo.query!("ALTER TABLE land_obs_call_counts RENAME TO land_obs_call_counts_moved")

      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)

      refute_received {:fetched, _}
      assert_received {@poll_error, ^ref, %{count: 1}, %{weather_time: ^wt, kind: :error}}
      assert log =~ "failed (error"
    end

    test "inside a caller's transaction: nothing reserved, fetched or stored" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      stub_primary(row(wt, 12.34))
      ref = attach([@poll, @store_refused])
      before = calls_today()

      log =
        capture_log(fn ->
          assert {:ok, {:snooze, _}} = Repo.transaction(fn -> run(wt) end)
        end)

      refute_received {:fetched, _}
      assert calls_today() == before

      assert_received {@poll, ^ref, %{count: 1}, %{ok?: false, error: :nested_transaction}}

      refute_received {@store_refused, ^ref, _, _}
      assert log =~ "failed (:nested_transaction)"
      assert Observations.for_draw(d.id) == nil
    end
  end

  describe "whole hours" do
    test "before the first poll (weather_time + 5 min) it waits, without fetching" do
      next_hour = DateTime.add(WindowedLandObsClient.floor_hour(DateTime.utc_now()), 3600)
      {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
      {_op, key} = create_v6_operator()
      put_v6_awaiting!(open_draw_with_entries(key), next_hour, s.round)
      stub_primary("[]")

      assert {:snooze, wait} = run(next_hour)
      expected = DateTime.diff(DateTime.add(next_hour, 5 * 60), DateTime.utc_now())
      assert abs(wait - expected) <= 2
      refute_received {:fetched, _}
    end

    test "the test client is the real client for a whole hour" do
      hour = ~U[2026-10-14 01:00:00Z]

      Req.Test.stub(LandObsClient, fn conn ->
        Plug.Conn.send_resp(conn, 200, row(hour, 12.34))
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

      assert_receive {@poll, ^ref, %{count: 1},
                      %{station: @primary, ok?: false, error: :no_api_key}}

      refute_receive {@poll, ^ref, _, _}
    end

    test "an exception during a poll snoozes until F instead of failing the job" do
      {wt, [d]} = v6_draws(-6 * 60, 1)
      ref = attach([@poll_error, @poll])
      # A non-string base URL makes the client raise inside the poll.
      Application.put_env(:wallop_core, LandObsClient, base_url: 123)

      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)
      assert Observations.for_draw(d.id) == nil

      # Counted in both events.
      assert_receive {@poll_error, ^ref, %{count: 1},
                      %{weather_time: ^wt, station: @primary, kind: :error}}

      assert_receive {@poll, ^ref, %{count: 1},
                      %{
                        station: @primary,
                        weather_time: ^wt,
                        ok?: false,
                        error: {:raised, :error}
                      }}

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

    test "a failed poll is logged at warning with only its reason" do
      {wt, _} = v6_draws(-6 * 60, 1)

      for {status, body, logged} <- [
            {503, "{}", "failed ({:unexpected_status, 503})"},
            {200, "[]", "failed (:missing_hour)"},
            {200, "not json", "failed (:invalid_json)"}
          ] do
        Req.Test.stub(LandObsClient, &Plug.Conn.send_resp(&1, status, body))
        log = capture_log([level: :warning], fn -> assert {:snooze, _} = run(wt) end)
        assert log =~ "[warning]"

        assert log =~
                 "WeatherObservationWorker: poll for #{WeatherObservationWorker.hour_arg(wt)}"

        assert log =~ logged
      end

      Req.Test.stub(LandObsClient, &Req.Test.transport_error(&1, :econnrefused))
      log = capture_log(fn -> assert {:snooze, _} = run(wt) end)
      assert log =~ "failed (:transport)"
    end

    test "a sentinel key and body never reach the log, whatever the error" do
      {wt, _} = v6_draws(-6 * 60, 1)
      key = "SENTINEL-KEY-0f9e8d7c"
      Application.put_env(:wallop_core, :met_office_obs_api_key, key)
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          for {status, body} <- [
                {401, ~s({"detail": "bad key SENTINEL-KEY-0f9e8d7c SENTINEL-BODY"})},
                {200, ~s([{"datetime": "SENTINEL-BODY"}])},
                {200, "SENTINEL-BODY"}
              ] do
            Req.Test.stub(LandObsClient, &Plug.Conn.send_resp(&1, status, body))
            assert {:snooze, _} = run(wt)
          end

          Req.Test.stub(LandObsClient, &Req.Test.transport_error(&1, :timeout))
          assert {:snooze, _} = run(wt)
        end)

      refute log =~ key
      refute log =~ "SENTINEL"

      # The poll lines name only the reason (the debug SQL above them names
      # the raw column, so only these lines are checked for it).
      failed = log |> String.split("\n") |> Enum.filter(&(&1 =~ "failed ("))
      assert length(failed) == 4
      refute Enum.any?(failed, &(&1 =~ "raw"))
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
      refute_receive {@poll, ^ref, _, _}

      for text <- [log, inspect(m1)] do
        refute text =~ "SHOULD-NOT-APPEAR"
      end
    end

    test "invalid job arguments cancel the job" do
      assert {:cancel, :invalid_weather_time} =
               perform_job(WeatherObservationWorker, %{weather_time: "not a time"})

      assert {:cancel, :invalid_weather_time} =
               perform_job(WeatherObservationWorker, %{weather_time: "2026-10-14T19:00:00+01:00"})
    end

    test "only the canonical argument runs" do
      for arg <- [
            "2026-10-14T19:00:00.000Z",
            "2026-10-14T19:00:00+00:00",
            "2026-10-14T19:00:00.5Z"
          ] do
        assert {:cancel, :invalid_weather_time} =
                 perform_job(WeatherObservationWorker, %{weather_time: arg}),
               arg
      end

      # The canonical form runs: an hour long past F stops without fetching.
      stub_primary("[]")

      assert :ok =
               perform_job(WeatherObservationWorker, %{weather_time: "2026-10-14T19:00:00Z"})

      refute_received {:fetched, _}
    end

    test "with the real client, only a whole hour runs" do
      assert {:ok, ~U[2026-10-14 19:00:00Z]} =
               WeatherObservationWorker.runnable_hour("2026-10-14T19:00:00Z", LandObsClient)

      for arg <- ["2026-10-14T19:00:01Z", "2026-10-14T19:30:00Z", "2026-10-14T19:00:00.000Z"] do
        assert WeatherObservationWorker.runnable_hour(arg, LandObsClient) == :error, arg
      end

      # The test client places "now" in a window with hours that aren't whole.
      assert {:ok, _} =
               WeatherObservationWorker.runnable_hour(
                 "2026-10-14T19:00:01Z",
                 WindowedLandObsClient
               )

      assert WeatherObservationWorker.runnable_hour(
               "2026-10-14T19:00:01.000Z",
               WindowedLandObsClient
             ) ==
               :error
    end

    test "the next poll is at least 5 s before F, and polling stops when it can't be" do
      wt = ~U[2026-10-14 19:00:00Z]
      f = Schedule.fetch_deadline(wt)
      at = fn ms -> DateTime.add(f, -ms, :millisecond) end

      assert WeatherObservationWorker.next_poll(at.(120_000), wt) ==
               {:snooze, Schedule.poll_interval_seconds()}

      assert WeatherObservationWorker.next_poll(at.(6_000), wt) == {:snooze, 1}
      assert WeatherObservationWorker.next_poll(at.(5_999), wt) == :ok
      assert WeatherObservationWorker.next_poll(at.(1_000), wt) == :ok
      assert WeatherObservationWorker.next_poll(at.(-1_000), wt) == :ok
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

  describe "the window follows from the database clock alone" do
    @wt ~N[2026-10-14 19:00:00.000000]

    test "window_state/2 mirrors the store's window exactly" do
      wt = ~U[2026-10-14 19:00:00.000000Z]
      f = Schedule.fetch_deadline(wt)

      assert WeatherObservationWorker.window_state(DateTime.add(wt, -1, :microsecond), wt) ==
               :not_yet

      assert WeatherObservationWorker.window_state(wt, wt) == :open
      assert WeatherObservationWorker.window_state(DateTime.add(wt, 1201), wt) == :open
      assert WeatherObservationWorker.window_state(f, wt) == :open

      assert WeatherObservationWorker.window_state(DateTime.add(f, 1, :microsecond), wt) ==
               :closed
    end

    defp sql_allowed(now) do
      %{rows: [[v]]} =
        Repo.query!("SELECT wallop_landobs_observation_allowed($1, $2, $3)", [@primary, @wt, now])

      v
    end

    defp worker_open?(now) do
      WeatherObservationWorker.window_state(
        DateTime.from_naive!(now, "Etc/UTC"),
        DateTime.from_naive!(@wt, "Etc/UTC")
      ) == :open
    end

    test "at every window boundary, the worker stores exactly when the store allows" do
      old_cutover = (@w - 10 * 60) * 1_000_000
      deadline = @w * 1_000_000

      for offset <- [
            -1,
            0,
            1,
            old_cutover,
            old_cutover + 1,
            deadline - 1,
            deadline,
            deadline + 1
          ] do
        now = NaiveDateTime.add(@wt, offset, :microsecond)
        assert worker_open?(now) == sql_allowed(now), "at #{offset}us"
      end
    end

    property "and at any instant around the window" do
      check all(offset <- integer(-3_600_000_000..(2 * @w * 1_000_000)), max_runs: 300) do
        now = NaiveDateTime.add(@wt, offset, :microsecond)
        assert worker_open?(now) == sql_allowed(now)
      end
    end
  end
end
