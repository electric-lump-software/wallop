defmodule WallopCore.Resources.Draw.LockV6RefusalsTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo
  import WallopCore.TestHelpers

  alias Ash.Error.Changes.InvalidArgument
  alias WallopCore.Entropy.{EntropyWorker, ObservationDrawWorker, WeatherObservationWorker}
  alias WallopCore.Resources.Draw
  alias WallopCore.Resources.Draw.Changes.SignAndStoreReceipt
  alias WallopCore.Weather.Schedule

  defp lock(draw, key, args),
    do: draw |> Ash.Changeset.for_update(:lock, args, actor: key) |> Ash.update()

  defp next_hour_draw_at(hours),
    do:
      DateTime.utc_now()
      |> DateTime.add(hours * 3600)
      |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 6}})

  defp reload(draw), do: Ash.get!(Draw, draw.id, authorize?: false, load: [:receipt])

  defp assert_untouched(draw) do
    open = reload(draw)
    assert open.status == :open
    assert {open.lock_schema_version, open.entropy_composition, open.receipt} == {nil, nil, nil}
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
    refute_enqueued(worker: EntropyWorker, args: %{draw_id: draw.id})
  end

  defp idempotency_rows(draw) do
    %{rows: rows} =
      WallopCore.Repo.query!(
        "SELECT * FROM add_entries_idempotency WHERE draw_id = $1 ORDER BY 1",
        [Ecto.UUID.dump!(draw.id)]
      )

    rows
  end

  defp refute_hour_enqueued(weather_time),
    do:
      refute_enqueued(
        worker: WeatherObservationWorker,
        args: %{weather_time: WeatherObservationWorker.hour_arg(weather_time)}
      )

  setup do
    ensure_infrastructure_key()
    :ok
  end

  test "a late draw_at is refused before the lock runs, with latest_lock_at; nothing changes" do
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)
    # The top of the previous hour: its observation hour's lock time has passed.
    draw_at = next_hour_draw_at(-1)
    {:ok, s} = Schedule.schedule(draw_at)

    assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
             lock(draw, key, %{draw_at: draw_at})

    assert error.field == :draw_at

    assert Keyword.get(error.vars, :latest_lock_at) ==
             DateTime.to_iso8601(DateTime.truncate(s.latest_lock_at, :second))

    assert_untouched(draw)
    refute_hour_enqueued(s.weather_time)
  end

  test "observation operators can't send weather_time, sub-second, off-grid, pre-genesis or beyond-cap draw times" do
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)
    ok = next_hour_draw_at(3)

    for {args, field, message} <- [
          {%{weather_time: ok}, :weather_time,
           "can't be set for this operator; send draw_at instead"},
          {%{draw_at: ok, weather_time: ok}, :weather_time,
           "can't be set for this operator; send draw_at instead"},
          {%{draw_at: DateTime.add(ok, 1)}, :draw_at,
           "must fall on drand quicknet's 3-second grid (any whole minute does)"},
          {%{draw_at: %{ok | microsecond: {500_000, 6}}}, :draw_at, "must have second precision"},
          {%{draw_at: ~U[2020-01-01 00:00:00.000000Z]}, :draw_at,
           "is before drand quicknet's first round"},
          {%{draw_at: next_hour_draw_at(24 * 7 + 2)}, :draw_at,
           "must be no more than 7 days (201,600 drand quicknet rounds) from now"}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = lock(draw, key, args)

      assert Enum.any?(errors, &match?(%InvalidArgument{field: ^field, message: ^message}, &1)),
             "#{inspect(args)}: #{inspect(errors)}"
    end

    assert_untouched(draw)
  end

  test "an in-time draw_at at the cap's edge is accepted" do
    {_op, key} = create_v6_operator()
    draw_at = next_hour_draw_at(24 * 7 - 2)
    assert {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
    assert locked.lock_schema_version == "6"
  end

  test "forecast operators can't send draw_at; the draw stays open" do
    key = create_api_key()
    draw = open_draw_with_entries(key)

    assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
             lock(draw, key, %{draw_at: next_hour_draw_at(3)})

    assert error.field == :draw_at

    assert error.message ==
             "is only available to operators on the observation-weather or grid-frequency protocol"

    assert_untouched(draw)
  end

  test "forecast operators: a nil draw_at is the same as none" do
    key = create_api_key()
    assert {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: nil})
    assert locked.lock_schema_version == nil
    assert_enqueued(worker: EntropyWorker, args: %{draw_id: locked.id})
  end

  # The validation passes, then the signer finds the lock late. Without a
  # clock seam, the changeset is built in time and its weather_time (which
  # the signer checks its own locked_at against) is then moved to an hour
  # whose latest lock time has passed: the state a slow lock reaches when
  # the clock crosses latest_lock_at between validation and signing.
  for sent? <- [true, false] do
    test "validation passes, the signer refuses (draw_at sent: #{sent?}): nothing is written" do
      {_op, key} = create_v6_operator()
      draw = open_draw_with_entries(key)
      idempotency = idempotency_rows(draw)
      assert idempotency != []

      args = if unquote(sent?), do: %{draw_at: next_hour_draw_at(3)}, else: %{}
      changeset = Ash.Changeset.for_update(draw, :lock, args, actor: key)
      assert changeset.valid?
      built_wt = Ash.Changeset.get_attribute(changeset, :weather_time)
      late_wt = next_hour_draw_at(-1)

      assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
               changeset
               |> Ash.Changeset.force_change_attribute(:weather_time, late_wt)
               |> Ash.update()

      assert error.message == "is too late: this draw must be locked by %{latest_lock_at}"
      assert error.field == if(unquote(sent?), do: :draw_at, else: nil)

      assert Keyword.get(error.vars, :latest_lock_at) ==
               late_wt
               |> Schedule.latest_lock_at()
               |> DateTime.truncate(:second)
               |> DateTime.to_iso8601()

      assert_untouched(draw)
      refute_hour_enqueued(built_wt)
      refute_hour_enqueued(late_wt)
      assert idempotency_rows(draw) == idempotency
    end
  end

  test "the signed locked_at is checked: one microsecond late is refused" do
    wt = ~U[2026-10-14 19:00:00.000000Z]
    assert SignAndStoreReceipt.v6_lock_time_error(~U[2026-10-14 18:14:00.000000Z], wt) == nil

    assert %InvalidArgument{
             field: :draw_at,
             message: "is too late: this draw must be locked by %{latest_lock_at}",
             vars: [latest_lock_at: "2026-10-14T18:14:00Z"]
           } = SignAndStoreReceipt.v6_lock_time_error(~U[2026-10-14 18:14:00.000001Z], wt)
  end

  describe "the fetching service's readiness" do
    @message "observation-weather draws are paused here: Land Observations readings can't be fetched right now"

    defp assert_refused(draw, key, args) do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = lock(draw, key, args)
      assert [%InvalidArgument{field: nil, message: @message}] = errors
    end

    test "no record: an observation lock is refused, with or without draw_at; nothing changes" do
      {_op, key} = create_v6_operator()
      put_observation_readiness!(nil)
      draw = open_draw_with_entries(key)
      draw_at = next_hour_draw_at(3)
      {:ok, s} = Schedule.schedule(draw_at)

      for args <- [%{draw_at: draw_at}, %{}], do: assert_refused(draw, key, args)

      assert_untouched(draw)
      refute_hour_enqueued(s.weather_time)
    end

    test "a record saying not ready refuses the lock" do
      {_op, key} = create_v6_operator()
      put_observation_readiness!(false)
      draw = open_draw_with_entries(key)
      assert_refused(draw, key, %{draw_at: next_hour_draw_at(3)})
      assert_untouched(draw)
    end

    test "a record older than 30 minutes by the database clock refuses the lock" do
      {_op, key} = create_v6_operator()
      draw = open_draw_with_entries(key)

      put_observation_readiness!(true, 30 * 60 + 5)
      assert_refused(draw, key, %{draw_at: next_hour_draw_at(3)})
      assert_untouched(draw)

      put_observation_readiness!(true, 30 * 60 - 60)

      assert {:ok, %{lock_schema_version: "6"}} =
               lock(draw, key, %{draw_at: next_hour_draw_at(3)})
    end

    test "the lock reads the record, not its own environment: no local key, ready record, accepted" do
      previous = Application.get_env(:wallop_core, :met_office_obs_api_key)
      Application.delete_env(:wallop_core, :met_office_obs_api_key)

      on_exit(fn ->
        if previous, do: Application.put_env(:wallop_core, :met_office_obs_api_key, previous)
      end)

      {_op, key} = create_v6_operator()
      put_observation_readiness!(true)

      assert {:ok, locked} =
               lock(open_draw_with_entries(key), key, %{draw_at: next_hour_draw_at(3)})

      assert locked.lock_schema_version == "6"
      assert locked.status == :awaiting_entropy
    end

    test "forecast and grid-frequency locks don't read it" do
      put_observation_readiness!(nil)
      key = create_api_key()
      assert {:ok, forecast} = lock(open_draw_with_entries(key), key, %{})
      assert forecast.lock_schema_version == nil
      assert_enqueued(worker: EntropyWorker, args: %{draw_id: forecast.id})

      {_op, freq_key} = create_freq_operator()

      assert {:ok, freq} =
               lock(open_draw_with_entries(freq_key), freq_key, %{
                 draw_at: next_hour_draw_at(3)
               })

      assert freq.lock_schema_version == "6"
      assert freq.entropy_composition == WallopCore.Protocol.freq_entropy_composition()
    end
  end
end
