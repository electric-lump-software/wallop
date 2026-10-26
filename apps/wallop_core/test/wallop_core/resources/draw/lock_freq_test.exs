defmodule WallopCore.Resources.Draw.LockFreqTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias Ash.Error.Changes.InvalidArgument
  alias WallopCore.Drand.Quicknet

  alias WallopCore.Entropy.{
    FrequencyWindowWorker,
    ObservationDrawWorker,
    WeatherObservationWorker
  }

  alias WallopCore.Entropy.V6Rules
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Resources.{Draw, Operator}
  alias WallopCore.Resources.Draw.Changes.SignAndStoreReceipt
  alias WallopCore.Resources.Draw.Validations.DrawAt
  alias WallopCore.Weather.Schedule, as: WeatherSchedule

  defp lock(draw, key, args),
    do: draw |> Ash.Changeset.for_update(:lock, args, actor: key) |> Ash.update()

  # A whole minute about `seconds` from now: on quicknet's grid.
  defp draw_at_in(seconds),
    do:
      DateTime.utc_now()
      |> DateTime.add(seconds)
      |> then(&%{&1 | second: 0, microsecond: {0, 6}})

  defp next_hour_draw_at(hours),
    do:
      DateTime.utc_now()
      |> DateTime.add(hours * 3600)
      |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 6}})

  defp set_protocol!(operator, protocol) do
    {:ok, operator} =
      operator
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: protocol})
      |> Ash.update(authorize?: false)

    operator
  end

  defp reload(draw), do: Ash.get!(Draw, draw.id, authorize?: false, load: [:receipt])

  defp assert_untouched(draw) do
    reloaded = reload(draw)
    assert reloaded.status == :open
    assert {reloaded.lock_schema_version, reloaded.entropy_composition} == {nil, nil}
    assert reloaded.freq_start == nil
    assert reloaded.receipt == nil
    refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
  end

  # The lock v6 builder's bytes for a locked draw, rebuilt from the stored row.
  defp rebuilt_v6_payload(locked, extra) do
    receipt = locked.receipt
    operator = Ash.get!(Operator, locked.operator_id, authorize?: false)

    %{
      entropy_composition: locked.entropy_composition,
      operator_id: operator.id,
      operator_slug: operator.slug,
      sequence: locked.operator_sequence,
      draw_id: locked.id,
      commitment_hash: locked.entry_hash,
      entry_hash: locked.entry_hash,
      locked_at: receipt.locked_at,
      signing_key_id: receipt.signing_key_id,
      winner_count: locked.winner_count,
      drand_chain: locked.drand_chain,
      drand_round: locked.drand_round,
      weather_station: locked.weather_station,
      weather_time: locked.weather_time,
      freq_start: locked.freq_start,
      wallop_core_version: to_string(Application.spec(:wallop_core, :vsn)),
      fair_pick_version: to_string(Application.spec(:fair_pick, :vsn))
    }
    |> Map.merge(extra)
    |> Protocol.build_v6_lock_payload()
  end

  setup do
    ensure_infrastructure_key()
    :ok
  end

  test "a frequency lock signs lock v6 under the frequency tag, derives everything, and enqueues both jobs" do
    {_op, key} = create_freq_operator()
    draw_at = draw_at_in(3600)
    {:ok, s} = Schedule.schedule(draw_at)

    assert {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
    locked = Ash.load!(locked, [:expected_result_at, :receipt], authorize?: false)

    assert locked.status == :awaiting_entropy
    assert {locked.lock_schema_version, locked.entropy_composition} == {"6", Freq.tag()}
    assert locked.drand_chain == Quicknet.chain_hash()
    assert {locked.drand_round, locked.freq_start} == {s.round, s.freq_start}
    assert {locked.weather_station, locked.weather_time} == {nil, nil}
    assert locked.expected_result_at == s.expected_result_at

    payload = Jason.decode!(locked.receipt.payload_jcs)
    assert Enum.sort(Map.keys(payload)) == Freq.lock_keys()
    assert length(Map.keys(payload)) == 20
    assert {payload["schema_version"], payload["entropy_composition"]} == {"6", Freq.tag()}
    assert payload["freq_start"] == WallopCore.Time.to_rfc3339_usec(s.freq_start)
    assert {payload["weather_station"], payload["weather_time"]} == {nil, nil}
    assert locked.receipt.payload_jcs == rebuilt_v6_payload(locked, %{freq_start: s.freq_start})

    assert_enqueued(
      worker: FrequencyWindowWorker,
      args: %{freq_start: FrequencyWindowWorker.start_arg(s.freq_start)},
      scheduled_at: DateTime.add(s.store_from, Schedule.first_poll_after_store_from_seconds())
    )

    assert_enqueued(
      worker: ObservationDrawWorker,
      args: %{draw_id: locked.id},
      scheduled_at: DateTime.add(s.expected_result_at, Schedule.execution_delay_seconds())
    )

    # No weather fetch job for any hour around the draw.
    for h <- -1..3 do
      hour =
        DateTime.utc_now()
        |> DateTime.add(h * 3600)
        |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 6}})

      refute_enqueued(
        worker: WeatherObservationWorker,
        args: %{weather_time: WeatherObservationWorker.hour_arg(hour)}
      )
    end
  end

  test "locked_at is taken once: the signed value, the receipt column and the stage timestamp agree" do
    {_op, key} = create_freq_operator()
    {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at_in(3600)})
    locked = Ash.load!(locked, [:receipt], authorize?: false)
    signed = Jason.decode!(locked.receipt.payload_jcs)["locked_at"]

    assert signed == WallopCore.Time.to_rfc3339_usec(locked.receipt.locked_at)
    assert signed == locked.stage_timestamps["locked_at"]
    assert Schedule.lock_allowed?(locked.receipt.locked_at, locked.freq_start)
  end

  test "without draw_at the earliest allowed draw time is used" do
    {_op, key} = create_freq_operator()
    draw = open_draw_with_entries(key)
    before = DateTime.utc_now()
    {:ok, locked} = lock(draw, key, %{})
    later = DateTime.utc_now()
    assert Schedule.freq_start_for_round(locked.drand_round) == locked.freq_start

    # The lock reads the clock once, somewhere between `before` and `later`,
    # so its draw time is the default for one of them: no wall-clock range.
    defaults =
      for now <- [before, later] do
        {:ok, s} = Schedule.schedule(Schedule.default_draw_at(now))
        {s.round, s.freq_start}
      end

    assert {locked.drand_round, locked.freq_start} in defaults
    assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: locked.id})

    assert_enqueued(
      worker: FrequencyWindowWorker,
      args: %{freq_start: FrequencyWindowWorker.start_arg(locked.freq_start)}
    )
  end

  test "two draws of the same window share one fetch job; each has its own execution job" do
    {_op, key} = create_freq_operator()
    draw_at = draw_at_in(3600)
    {:ok, a} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
    {:ok, b} = lock(open_draw_with_entries(key), key, %{draw_at: DateTime.add(draw_at, 3)})
    assert a.freq_start == b.freq_start

    assert [_] =
             all_enqueued(
               worker: FrequencyWindowWorker,
               args: %{freq_start: FrequencyWindowWorker.start_arg(a.freq_start)}
             )

    assert [_] = all_enqueued(worker: ObservationDrawWorker, args: %{draw_id: a.id})
    assert [_] = all_enqueued(worker: ObservationDrawWorker, args: %{draw_id: b.id})
  end

  test "an operator flag flip between building and running the lock aborts it" do
    for to <- [:observation] do
      {op, key} = create_freq_operator()
      draw = open_draw_with_entries(key)
      changeset = Ash.Changeset.for_update(draw, :lock, %{draw_at: draw_at_in(3600)}, actor: key)
      set_protocol!(op, to)

      assert {:error, %Ash.Error.Invalid{} = error} = Ash.update(changeset)
      assert Exception.message(error) =~ "the operator's draw protocol changed during the lock"
      assert_untouched(draw)
    end
  end

  test "an observation lock built before a flip to frequency is aborted too" do
    {op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)

    changeset =
      Ash.Changeset.for_update(draw, :lock, %{draw_at: next_hour_draw_at(3)}, actor: key)

    set_protocol!(op, :frequency)

    assert {:error, %Ash.Error.Invalid{} = error} = Ash.update(changeset)
    assert Exception.message(error) =~ "the operator's draw protocol changed during the lock"
    assert_untouched(draw)
  end

  test "a frequency draw stays frequency when the operator is switched after lock" do
    {op, key} = create_freq_operator()
    {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at_in(3600)})

    for to <- [:observation] do
      set_protocol!(op, to)
      reloaded = Ash.get!(Draw, locked.id, authorize?: false)
      assert {reloaded.lock_schema_version, reloaded.entropy_composition} == {"6", Freq.tag()}
      assert reloaded.freq_start == locked.freq_start
    end
  end

  test "the signed locked_at is checked: T - 60 s exactly is fine, 1 us later is refused" do
    t = ~U[2026-10-14 19:54:15.000000Z]
    assert SignAndStoreReceipt.freq_lock_time_error(~U[2026-10-14 19:53:15.000000Z], t) == nil

    assert %InvalidArgument{
             field: :draw_at,
             message: "is too late: this draw must be locked by %{latest_lock_at}",
             vars: [latest_lock_at: "2026-10-14T19:53:15Z"]
           } = SignAndStoreReceipt.freq_lock_time_error(~U[2026-10-14 19:53:15.000001Z], t)

    assert %InvalidArgument{field: nil} =
             SignAndStoreReceipt.freq_lock_time_error(~U[2026-10-14 19:53:15.000001Z], t, nil)
  end

  test "a late draw_at is refused by validation with latest_lock_at; nothing is written" do
    {_op, key} = create_freq_operator()
    draw = open_draw_with_entries(key)
    # A draw time whose T - 60 s has passed: its round published a minute ago.
    late = draw_at_in(-60)
    {:ok, s} = Schedule.schedule(late)

    # Refused by validation, when the changeset is built: before any write.
    changeset = Ash.Changeset.for_update(draw, :lock, %{draw_at: late}, actor: key)
    refute changeset.valid?
    assert [%InvalidArgument{field: :draw_at}] = changeset.errors

    assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
             lock(draw, key, %{draw_at: late})

    assert error.field == :draw_at
    assert error.message == "is too late: this draw must be locked by %{latest_lock_at}"

    assert Keyword.get(error.vars, :latest_lock_at) ==
             s.latest_lock_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    assert_untouched(draw)
  end

  test "a frequency draw_at is checked against the frequency schedule, not the weather one" do
    {_op, key} = create_freq_operator()
    # Ten minutes ahead: in time for grid frequency (T - 60 s is about 3 minutes
    # ahead), far too late for an observation-weather draw (hour minus 46 minutes).
    draw_at = draw_at_in(600)
    {:ok, ws} = WeatherSchedule.schedule(draw_at)
    refute WeatherSchedule.lock_allowed?(DateTime.utc_now(), ws.weather_time)

    assert {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
    assert locked.entropy_composition == Freq.tag()
  end

  for sent? <- [true, false] do
    @sent sent?
    test "validation passes, the signer refuses: nothing is written (draw_at sent: #{sent?})" do
      {_op, key} = create_freq_operator()
      draw = open_draw_with_entries(key)
      args = if @sent, do: %{draw_at: draw_at_in(3600)}, else: %{}
      changeset = Ash.Changeset.for_update(draw, :lock, args, actor: key)
      assert changeset.valid?
      in_time_t = Ash.Changeset.get_attribute(changeset, :freq_start)

      # The state a slow lock reaches when the clock crosses T - 60 s between
      # validation and signing: the signer's freq_start is now in the past.
      late_t = aligned_freq_start(-600)

      assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
               changeset
               |> Ash.Changeset.force_change_attribute(:freq_start, late_t)
               |> Ash.update()

      assert error.field == if(@sent, do: :draw_at, else: nil)

      assert Keyword.get(error.vars, :latest_lock_at) ==
               late_t
               |> Schedule.latest_lock_at()
               |> DateTime.truncate(:second)
               |> DateTime.to_iso8601()

      assert_untouched(draw)

      for t <- [late_t, in_time_t] do
        refute_enqueued(
          worker: FrequencyWindowWorker,
          args: %{freq_start: FrequencyWindowWorker.start_arg(t)}
        )
      end
    end
  end

  describe "a schema 6 tag with no rules is refused, never guessed" do
    @unknown "drand-quicknet+elexon-freq-v2"

    test "DrawAt refuses a draw_at under it" do
      {_op, key} = create_freq_operator()

      changeset =
        open_draw_with_entries(key)
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:lock_schema_version, "6")
        |> Ash.Changeset.force_change_attribute(:entropy_composition, @unknown)
        |> Ash.Changeset.set_argument(:draw_at, draw_at_in(3600))

      assert {:error, %InvalidArgument{field: :draw_at, message: message}} =
               DrawAt.validate(changeset, [], %{})

      assert message == V6Rules.unknown_pair_message("6", @unknown)
    end

    test "the signer refuses to sign under it; nothing is written" do
      {_op, key} = create_freq_operator()
      draw = open_draw_with_entries(key)
      changeset = Ash.Changeset.for_update(draw, :lock, %{draw_at: draw_at_in(3600)}, actor: key)
      assert changeset.valid?

      assert {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{} = error]}} =
               changeset
               |> Ash.Changeset.force_change_attribute(:entropy_composition, @unknown)
               |> Ash.update()

      assert {error.field, error.message} == {nil, V6Rules.unknown_pair_message("6", @unknown)}
      assert_untouched(draw)
    end
  end

  describe "the lock broadcast" do
    defp subscribe(draw), do: Phoenix.PubSub.subscribe(WallopCore.PubSub, "draw:#{draw.id}")

    defp broadcasts(id) do
      receive do
        {:draw_updated, %{id: ^id} = d} -> [d | broadcasts(id)]
      after
        100 -> []
      end
    end

    # Fails the lock after every other after_action has run (the enqueue,
    # LockDraw's and the receipt insert), so the whole lock rolls back last.
    # A before_action added here runs after the lock's own; the after_action
    # it adds is the last one registered.
    defp fail_last(changeset) do
      Ash.Changeset.before_action(changeset, fn cs ->
        Ash.Changeset.after_action(cs, fn _cs, _draw -> {:error, "rolled back last"} end)
      end)
    end

    for {name, setup} <- [
          {"grid-frequency", {:freq, 3600}},
          {"observation-weather", {:observation, 3}}
        ] do
      @setup setup
      test "a committed #{name} lock is announced once, as locked" do
        {draw, key, args} = v6_lock_setup(@setup)
        subscribe(draw)
        assert {:ok, _} = lock(draw, key, args)
        assert [%{status: :awaiting_entropy}] = broadcasts(draw.id)
      end

      test "a rolled-back #{name} lock is never announced" do
        {draw, key, args} = v6_lock_setup(@setup)
        changeset = Ash.Changeset.for_update(draw, :lock, args, actor: key)
        subscribe(draw)
        assert {:error, err} = changeset |> fail_last() |> Ash.update()
        assert Exception.message(err) =~ "rolled back last"
        assert Ash.get!(Draw, draw.id, authorize?: false).status == :open
        assert broadcasts(draw.id) == []
        # The rolled-back lock takes its jobs with it, T's window job included.
        refute_enqueued(worker: FrequencyWindowWorker)
        refute_enqueued(worker: ObservationDrawWorker, args: %{draw_id: draw.id})
      end
    end

    defp v6_lock_setup({:freq, seconds}) do
      {_op, key} = create_freq_operator()
      {open_draw_with_entries(key), key, %{draw_at: draw_at_in(seconds)}}
    end

    defp v6_lock_setup({:observation, hours}) do
      {_op, key} = create_v6_operator()
      {open_draw_with_entries(key), key, %{draw_at: next_hour_draw_at(hours)}}
    end
  end

  describe "the other protocol's locks are unchanged" do
    test "an observation lock: the Land Obs receipt bytes, its round's freq_start, its own jobs" do
      {_op, key} = create_v6_operator()
      draw_at = next_hour_draw_at(3)
      {:ok, locked} = lock(open_draw_with_entries(key), key, %{draw_at: draw_at})
      locked = reload(locked)

      assert {locked.lock_schema_version, locked.entropy_composition} == {"6", LandObs.tag()}
      assert locked.freq_start == Schedule.freq_start_for_round(locked.drand_round)
      assert locked.receipt.payload_jcs == rebuilt_v6_payload(locked, %{})
      assert Enum.sort(Map.keys(Jason.decode!(locked.receipt.payload_jcs))) == LandObs.lock_keys()

      assert_enqueued(
        worker: WeatherObservationWorker,
        args: %{weather_time: WeatherObservationWorker.hour_arg(locked.weather_time)}
      )

      assert_enqueued(worker: ObservationDrawWorker, args: %{draw_id: locked.id})
    end
  end
end
