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
             WallopCore.Time.to_rfc3339_usec(s.latest_lock_at)

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
           "must be within 7 days (201,600 drand quicknet rounds)"}
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
    assert error.message == "is only available to operators on the observation weather protocol"
    assert_untouched(draw)
  end

  test "forecast operators: a nil draw_at is the same as none" do
    key = create_api_key()
    assert {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: nil})
    assert locked.lock_schema_version == nil
    assert_enqueued(worker: EntropyWorker, args: %{draw_id: locked.id})
  end

  test "the signed locked_at is checked: one microsecond late is refused" do
    wt = ~U[2026-10-14 19:00:00.000000Z]
    assert SignAndStoreReceipt.v6_lock_time_error(~U[2026-10-14 18:14:00.000000Z], wt) == nil

    assert %InvalidArgument{
             field: :draw_at,
             message: "is too late to lock for: lock by %{latest_lock_at} for this draw time",
             vars: [latest_lock_at: "2026-10-14T18:14:00.000000Z"]
           } = SignAndStoreReceipt.v6_lock_time_error(~U[2026-10-14 18:14:00.000001Z], wt)
  end
end
