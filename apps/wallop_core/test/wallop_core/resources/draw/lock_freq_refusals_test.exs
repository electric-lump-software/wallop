defmodule WallopCore.Resources.Draw.LockFreqRefusalsTest do
  @moduledoc """
  Grid-frequency lock refusals. Two cases live in `lock_freq_test.exs` and
  are not repeated here: a draw time already past ("a late draw_at is
  refused by validation with latest_lock_at") and the frequency schedule
  being the one checked ("a frequency draw_at is checked against the
  frequency schedule, not the weather one"). The forecast refusal's wording
  is pinned in `lock_v6_refusals_test.exs`.
  """
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Resource.Info
  alias WallopCore.Entropy.{FrequencyWindowWorker, ObservationDrawWorker}
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Resources.Draw

  defp lock(draw, key, args),
    do: draw |> Ash.Changeset.for_update(:lock, args, actor: key) |> Ash.update()

  defp minute_after(seconds),
    do:
      DateTime.utc_now()
      |> DateTime.add(seconds)
      |> then(&%{&1 | second: 0, microsecond: {0, 6}})

  setup do
    ensure_infrastructure_key()
    :ok
  end

  test "a draw time about six minutes ahead is already too late: latest_lock_at = T - 60 s" do
    {_op, key} = create_freq_operator()
    draw = open_draw_with_entries(key)
    # pub(R) - now is in (300, 360] s, and T - 60 s is pub(R) - 420 s or
    # earlier, so it is always before now.
    late = minute_after(360)
    {:ok, s} = Schedule.schedule(late)
    assert DateTime.compare(s.latest_lock_at, DateTime.utc_now()) == :lt

    assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
             lock(draw, key, %{draw_at: late})

    assert error.field == :draw_at
    assert error.message == "is too late: this draw must be locked by %{latest_lock_at}"

    assert Keyword.get(error.vars, :latest_lock_at) ==
             s.latest_lock_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    assert Ash.get!(Draw, draw.id, authorize?: false).status == :open
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})

    refute_enqueued(
      worker: FrequencyWindowWorker,
      args: %{freq_start: FrequencyWindowWorker.start_arg(s.freq_start)}
    )
  end

  test "frequency operators can't send weather_time, or sub-second, off-grid, pre-genesis or beyond-cap draw times" do
    {_op, key} = create_freq_operator()
    d = open_draw_with_entries(key)
    ok = minute_after(3600)

    for {args, field, message} <- [
          {%{weather_time: ok}, :weather_time,
           "can't be set for this operator; send draw_at instead"},
          {%{draw_at: %{ok | microsecond: {500_000, 6}}}, :draw_at, "must have second precision"},
          {%{draw_at: DateTime.add(ok, 1)}, :draw_at,
           "must fall on drand quicknet's 3-second grid (any whole minute does)"},
          {%{draw_at: ~U[2020-01-01 00:00:00.000000Z]}, :draw_at,
           "is before drand quicknet's first round"},
          {%{draw_at: minute_after(7 * 86_400 + 600)}, :draw_at,
           "must be no more than 7 days (201,600 drand quicknet rounds) from now"}
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} = lock(d, key, args)

      assert Enum.any?(errors, &match?(%InvalidArgument{field: ^field, message: ^message}, &1)),
             inspect(args)
    end

    assert Ash.get!(Draw, d.id, authorize?: false).status == :open
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: d.id})
  end

  test "the draw_at description names both protocols' lock rules and the forecast refusal" do
    %{description: text} =
      Enum.find(Info.action(Draw, :lock).arguments, &(&1.name == :draw_at))

    for phrase <- [
          "Observation-weather and grid-frequency operators only",
          "a forecast operator's lock is refused if it sends draw_at",
          "the observation hour minus 46 minutes (observation weather)",
          "60 seconds before the first of the 8 grid-frequency readings",
          "meta.latest_lock_at"
        ] do
      assert text =~ phrase, phrase
    end
  end
end
