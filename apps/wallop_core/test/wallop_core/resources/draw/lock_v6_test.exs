defmodule WallopCore.Resources.Draw.LockV6Test do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo
  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet

  alias WallopCore.Entropy.{
    FrequencyWindowWorker,
    ObservationDrawWorker,
    WeatherObservationWorker
  }

  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  defp lock(draw, key, args),
    do: draw |> Ash.Changeset.for_update(:lock, args, actor: key) |> Ash.update()

  defp next_hour_draw_at(hours),
    do:
      DateTime.utc_now()
      |> DateTime.add(hours * 3600)
      |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 6}})

  defp reload(draw), do: Ash.get!(Draw, draw.id, authorize?: false, load: [:receipt])

  defp set_protocol!(operator, protocol) do
    {:ok, operator} =
      operator
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: protocol})
      |> Ash.update(authorize?: false)

    operator
  end

  setup do
    ensure_infrastructure_key()
    :ok
  end

  test "a v6 lock with draw_at signs lock v6, derives everything, and enqueues all three jobs" do
    {_op, key} = create_v6_operator()
    draw_at = next_hour_draw_at(3)
    {:ok, s} = Schedule.schedule(draw_at)
    assert {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
    locked = Ash.load!(locked, [:expected_result_at, :receipt], authorize?: false)

    assert locked.status == :awaiting_entropy
    assert {locked.lock_schema_version, locked.entropy_composition} == {"6", LandObs.tag()}
    assert locked.drand_chain == Quicknet.chain_hash()
    assert locked.drand_round == s.round
    assert locked.weather_time == s.weather_time
    assert locked.expected_result_at == s.expected_result_at
    assert locked.weather_station == Stations.primary().id
    assert locked.weather_station == "wmo-03749"

    payload = Jason.decode!(locked.receipt.payload_jcs)
    assert payload["schema_version"] == "6"
    assert payload["entropy_composition"] == "drand-quicknet+metoffice-landobs-v1"
    assert payload["drand_round"] == s.round
    assert payload["weather_time"] == WallopCore.Time.to_rfc3339_usec(s.weather_time)
    assert payload["weather_station"] == "wmo-03749"

    assert locked.freq_start == WallopCore.Frequency.Schedule.freq_start_for_round(s.round)

    assert Jason.decode!(locked.receipt.payload_jcs)["freq_start"] ==
             WallopCore.Time.to_rfc3339_usec(locked.freq_start)

    assert_enqueued(
      worker: WeatherObservationWorker,
      args: %{weather_time: WeatherObservationWorker.hour_arg(s.weather_time)},
      scheduled_at: DateTime.add(s.weather_time, 300)
    )

    assert_enqueued(
      worker: ObservationDrawWorker,
      args: %{draw_id: locked.id},
      scheduled_at: DateTime.add(s.expected_result_at, 5)
    )

    assert_enqueued(
      worker: FrequencyWindowWorker,
      args: %{freq_start: FrequencyWindowWorker.start_arg(locked.freq_start)},
      scheduled_at: DateTime.add(locked.freq_start, 135)
    )
  end

  test "locked_at is taken once: the signed value, the receipt column and the stage timestamp agree" do
    {_op, key} = create_v6_operator()
    {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: next_hour_draw_at(3)})
    locked = reload(locked)

    signed = Jason.decode!(locked.receipt.payload_jcs)["locked_at"]
    assert signed == WallopCore.Time.to_rfc3339_usec(locked.receipt.locked_at)
    {:ok, stage, 0} = DateTime.from_iso8601(locked.stage_timestamps["locked_at"])
    assert WallopCore.Time.to_rfc3339_usec(stage) == signed
    assert Schedule.lock_allowed?(locked.receipt.locked_at, locked.weather_time)
  end

  test "a v6 lock without draw_at uses the earliest allowed draw time" do
    {_op, key} = create_v6_operator()
    before = DateTime.utc_now()
    {:ok, locked} = lock(open_draw_with_entries(key), key, %{})
    later = DateTime.utc_now()
    assert locked.lock_schema_version == "6"
    assert DateTime.diff(locked.weather_time, before) >= 46 * 60
    assert DateTime.diff(locked.weather_time, before) < 46 * 60 + 3600 + 60

    # The lock reads the clock once, between `before` and `later`; the
    # default moves on at hh:13:30, which may fall between the two.
    defaults =
      for now <- [before, later], do: Quicknet.round_at_or_after(Schedule.default_draw_at(now))

    assert locked.drand_round in defaults
    assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: locked.id})
  end

  test "two draws of the same hour share one fetch job" do
    {_op, key} = create_v6_operator()
    draw_at = next_hour_draw_at(3)
    {:ok, a} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
    {:ok, b} = lock(open_draw_with_entries(key), key, %{draw_at: DateTime.add(draw_at, 60)})
    assert a.weather_time == b.weather_time
    hour = %{weather_time: WeatherObservationWorker.hour_arg(a.weather_time)}
    assert length(all_enqueued(worker: WeatherObservationWorker, args: hour)) == 1

    for draw <- [a, b] do
      assert length(all_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})) == 1
    end
  end

  # Refused by the DrawAt validation before the lock runs; the same check on
  # the signed locked_at is unit-tested in LockV6RefusalsTest.
  test "a late draw_at is refused; the draw stays open and nothing is enqueued" do
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)
    # The latest observation hour whose lock time has passed.
    latest = DateTime.to_unix(DateTime.utc_now()) + Schedule.lock_offset_seconds() - 1
    wt = DateTime.from_unix!((latest - Integer.mod(latest, 3600)) * 1_000_000, :microsecond)
    round = Quicknet.round_at_or_after(DateTime.add(wt, Schedule.fetch_window_seconds() + 60))
    {:ok, s} = Schedule.schedule(Quicknet.pub_time(round))

    assert {:error, %Ash.Error.Invalid{errors: [error | _]}} =
             lock(draw, key, %{draw_at: s.draw_at})

    assert error.field == :draw_at

    assert Keyword.get(error.vars, :latest_lock_at) ==
             DateTime.to_iso8601(DateTime.truncate(s.latest_lock_at, :second))

    open = reload(draw)
    assert open.status == :open
    assert {open.lock_schema_version, open.entropy_composition, open.receipt} == {nil, nil, nil}
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})

    refute_enqueued(
      worker: WeatherObservationWorker,
      args: %{weather_time: WeatherObservationWorker.hour_arg(s.weather_time)}
    )

    refute_enqueued(worker: FrequencyWindowWorker)
  end

  test "an operator flag flip between building and running the lock aborts it" do
    {op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)

    changeset =
      Ash.Changeset.for_update(draw, :lock, %{draw_at: next_hour_draw_at(3)}, actor: key)

    set_protocol!(op, :frequency)
    assert {:error, %Ash.Error.Invalid{}} = Ash.update(changeset)

    assert reload(draw).status == :open
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
  end

  test "a plain lock of a new operator is an observation-weather lock" do
    put_observation_readiness!(true)
    key = create_api_key()
    {:ok, locked} = lock(open_draw_with_entries(key), key, %{})
    locked = reload(locked)
    assert locked.lock_schema_version == "6"
    assert locked.entropy_composition == LandObs.tag()
    assert Jason.decode!(locked.receipt.payload_jcs)["schema_version"] == "6"
    assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: locked.id})
  end

  test "a lock that sends weather_time is refused; the draw stays open" do
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)
    wt = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)

    assert {:error, %Ash.Error.Invalid{}} = lock(draw, key, %{weather_time: wt})
    assert reload(draw).status == :open
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
  end

  test "a raw-SQL lock that leaves lock_schema_version NULL is refused by the database" do
    # Older core code locks without knowing the flag; the database refuses it.
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)

    assert db_refused?(
             "UPDATE draws SET status = 'awaiting_entropy', weather_time = $2 WHERE id = $1",
             [
               Ecto.UUID.dump!(draw.id),
               DateTime.to_naive(DateTime.add(DateTime.utc_now(), 600))
             ]
           )

    open = Ash.get!(Draw, draw.id, authorize?: false)
    assert {open.status, open.lock_schema_version} == {:open, nil}
  end
end
