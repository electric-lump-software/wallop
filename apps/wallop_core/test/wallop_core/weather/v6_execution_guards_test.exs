defmodule WallopCore.Weather.V6ExecutionGuardsTest do
  @moduledoc """
  The database guards on how an observation-weather (v6) draw ends: the
  execution receipt guard, the delete guard, and the fallback grace in the
  completion guard. Every one is a no-op for a draw with no lock schema
  (every forecast and historic draw), and each test that says so proves it.
  The refusal of `failed` after pub(R) is pinned by INV-9.
  """
  # Not async: the observation store has one row per hour across the database.
  use WallopCore.DataCase, async: false

  import WallopCore.InvariantCase, except: [__using__: 1]
  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @value "141;1025;85;2432"
  @not_valid "v6 execution receipt signing key was not valid at executed_at"
  @grace "a v6 execution receipt may fall back only after the fetch deadline with nothing stored"
  @no_delete "a v6 draw can't be deleted once it has left open"
  @fallback_late "v6 draw may fall back only after the fetch deadline with nothing stored"

  defp build(input), do: Protocol.build_v6_execution_payload(input)

  # The signer's payload for `x`, with the drand pair put in by hand (the
  # builder may refuse it), for checking the database alone.
  defp raw_payload(x, randomness, signature) do
    x.input
    |> build()
    |> Jason.decode!()
    |> Map.merge(%{"drand_randomness" => randomness, "drand_signature" => signature})
  end

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  # A stored weather_time whose fetch deadline F was `ago` seconds ago.
  defp wt_with_deadline_ago(ago),
    do: DateTime.utc_now() |> DateTime.add(-(@w + ago)) |> DateTime.truncate(:second)

  defp forecast_cols(draw),
    do: %{
      draw_id: draw.id,
      operator_id: draw.operator_id,
      sequence: 1_000_000 + System.unique_integer([:positive]),
      lock_receipt_hash: "x",
      signing_key_id: "k"
    }

  # State (c): no reading and no window, so drand alone.
  defp complete_by_fallback(draw) do
    try_sql(
      """
      UPDATE draws SET status = 'completed', executed_at = $2, weather_fallback_reason = $3,
        freq_fallback_reason = $4
      WHERE id = $1
      """,
      [dump(draw.id), NaiveDateTime.utc_now(), LandObs.fallback_reason(), Freq.fallback_reason()]
    )
  end

  defp pending_v6(wt) do
    {_op, key} = create_v6_operator()
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(-10))
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    draw
  end

  describe "the execution receipt guard" do
    test "is in place on execution_receipts" do
      assert %{rows: [["O"]]} =
               Repo.query!(
                 "SELECT tgenabled::text FROM pg_trigger WHERE tgname = 'execution_receipts_v6_guard'"
               )
    end

    test "leaves a forecast draw's execution receipts alone, refusing only schema 5" do
      draw = create_draw(create_api_key())

      for payload <- ["not json", ~s({"schema_version":"4"}), ~s([5]), ~s("5")] do
        assert insert_exec_receipt(payload, forecast_cols(draw)) == nil, payload
      end

      assert insert_exec_receipt(~s({"schema_version":"5"}), forecast_cols(draw)) ==
               "a schema 5 execution receipt needs a draw locked under schema 6"
    end

    test "accepts the signer's receipt in each of the three states" do
      for {kind, hours} <- [observed: 1, frequency: 2, fallback: 3] do
        x = completed_v6_receipt_input(kind, hours_ago: hours)
        assert insert_exec_receipt(build(x.input), x.cols) == nil, "#{kind}"
      end
    end

    test "an open draw that already has an execution receipt can't lock under v6" do
      # The guard reads a forecast draw's pair without a lock, so a receipt
      # could reach an open draw that a concurrent lock is making v6; the
      # lock then refuses it.
      {_op, key} = create_v6_operator()
      s = in_time_schedule()
      draw = open_draw_with_entries(key)
      cols = %{forecast_cols(draw) | sequence: draw.operator_sequence}

      Repo.query!(
        """
        INSERT INTO execution_receipts (id, draw_id, operator_id, sequence, lock_receipt_hash,
          payload_jcs, signature, signing_key_id)
        VALUES ($1, $2, $3, $4, 'x', $5, $6, 'k')
        """,
        [
          dump(Ecto.UUID.generate()),
          dump(draw.id),
          dump(cols.operator_id),
          cols.sequence,
          ~s({"schema_version":"4"}),
          :binary.copy(<<0>>, 64)
        ]
      )

      assert raw_lock(draw, s.weather_time, s.round) ==
               "a v6 draw can't lock with an execution receipt already stored"
    end

    test "needs the draw completed first" do
      x = completed_v6_receipt_input(:fallback)

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
          dump(x.draw.id)
        ])
      end)

      assert insert_exec_receipt(build(x.input), x.cols) ==
               "a v6 execution receipt needs its draw completed first"
    end

    test "needs the draw's lock receipt" do
      x = completed_v6_receipt_input(:fallback)

      with_triggers_off(fn ->
        Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(x.draw.id)])
      end)

      assert insert_exec_receipt(build(x.input), x.cols) ==
               "a v6 execution receipt needs its draw's lock receipt"
    end

    test "needs an infrastructure key that was in the keyring, and eligible, at executed_at" do
      x = completed_v6_receipt_input(:observed)
      executed_at = DateTime.to_naive(x.input.executed_at)

      late_insert = create_infrastructure_key()
      late_valid = create_infrastructure_key()

      with_triggers_off(fn ->
        Repo.query!(
          "UPDATE infrastructure_signing_keys SET inserted_at = $2::timestamp + interval '1 second' WHERE key_id = $1",
          [late_insert.key_id, executed_at]
        )

        Repo.query!(
          "UPDATE infrastructure_signing_keys SET valid_from = $2::timestamp + interval '1 microsecond' WHERE key_id = $1",
          [late_valid.key_id, executed_at]
        )
      end)

      for key_id <- [late_insert.key_id, late_valid.key_id, "deadbeef"] do
        input = %{x.input | signing_key_id: key_id}
        cols = %{x.cols | signing_key_id: key_id}
        assert insert_exec_receipt(build(input), cols) == @not_valid, key_id
      end
    end

    test "a fallback receipt waits a minute past the fetch deadline" do
      # Completed with triggers off: the completion guard would refuse it.
      early =
        completed_v6_receipt_input(:fallback,
          weather_time: wt_with_deadline_ago(30),
          triggers_off: true
        )

      assert insert_exec_receipt(build(early.input), early.cols) == @grace

      later = completed_v6_receipt_input(:fallback, weather_time: wt_with_deadline_ago(90))
      assert insert_exec_receipt(build(later.input), later.cols) == nil
    end

    test "a reading for a fallback hour is refused" do
      x = completed_v6_receipt_input(:fallback)

      input = %{
        x.input
        | weather_value: @value,
          weather_observation_time: x.wt,
          weather_fallback_reason: nil,
          freq_fallback_reason: nil
      }

      assert insert_exec_receipt(build(input), x.cols) ==
               "v6 execution receipt field weather_value does not match the stored observation"
    end

    test "another station than the stored reading's is refused" do
      x = completed_v6_receipt_input(:observed)
      assert x.input.weather_station == Stations.primary().id

      tampered =
        x.input |> build() |> Jason.decode!() |> Map.put("weather_station", "wmo-03462")

      assert insert_exec_receipt(Jason.encode!(tampered), x.cols) ==
               "v6 execution receipt field weather_station does not match the stored observation"
    end
  end

  describe "the three states" do
    # The signer's receipt for state `kind`, with `key` set to `value` (a
    # decoded JSON term) and nothing else changed.
    defp receipt_with(x, key, value),
      do: x.input |> build() |> Jason.decode!() |> Map.put(key, value) |> Jason.encode!()

    defp refusal(field),
      do: "v6 execution receipt field #{field} does not match the stored observation"

    @freq "50012;50018;50012;49983;49980;49953;49912;49883"

    test "(a) refuses either freq field set" do
      x = completed_v6_receipt_input(:observed, hours_ago: 1)
      assert insert_exec_receipt(build(x.input), x.cols) == nil

      assert insert_exec_receipt(receipt_with(x, "freq_value", @freq), x.cols) ==
               refusal("freq_value")

      assert insert_exec_receipt(
               receipt_with(x, "freq_fallback_reason", Freq.fallback_reason()),
               x.cols
             ) == refusal("freq_fallback_reason")
    end

    test "(b) refuses a freq_value that is null, a number or another window, and a freq reason" do
      x = completed_v6_receipt_input(:frequency, hours_ago: 2, freq_value: @freq)
      assert insert_exec_receipt(build(x.input), x.cols) == nil

      for value <- [nil, 50_012, "50018;50012;49983;49980;49953;49912;49883;49887"] do
        assert insert_exec_receipt(receipt_with(x, "freq_value", value), x.cols) ==
                 refusal("freq_value"),
               inspect(value)
      end

      assert insert_exec_receipt(
               receipt_with(x, "freq_fallback_reason", Freq.fallback_reason()),
               x.cols
             ) == refusal("freq_fallback_reason")

      # The weather side of (b) is the weather fallback's.
      assert insert_exec_receipt(receipt_with(x, "weather_fallback_reason", nil), x.cols) ==
               refusal("weather_fallback_reason")
    end

    test "(c) refuses a missing freq reason, another reason, or a freq_value" do
      x = completed_v6_receipt_input(:fallback, hours_ago: 3)
      assert insert_exec_receipt(build(x.input), x.cols) == nil

      for reason <- [nil, "no_observation_by_deadline"] do
        assert insert_exec_receipt(receipt_with(x, "freq_fallback_reason", reason), x.cols) ==
                 refusal("freq_fallback_reason"),
               inspect(reason)
      end

      assert insert_exec_receipt(receipt_with(x, "freq_value", @freq), x.cols) ==
               refusal("freq_value")
    end

    test "(c) waits until M past T's fetch deadline; (b) does not need to" do
      # T 300 s back on the 15 s grid: F_freq + M = T + 360 s is still ahead,
      # while the weather's F + 1 min is long past. Completed with triggers
      # off: the completion guard would refuse (c) too.
      t = aligned_freq_start(-300)

      early =
        completed_v6_receipt_input(:fallback, hours_ago: 4, freq_start: t, triggers_off: true)

      assert insert_exec_receipt(build(early.input), early.cols) == @grace

      stored =
        completed_v6_receipt_input(:frequency,
          hours_ago: 5,
          freq_start: aligned_freq_start(-285),
          freq_value: @freq,
          triggers_off: true
        )

      assert insert_exec_receipt(build(stored.input), stored.cols) == nil
    end
  end

  describe "receipt key sets" do
    test "the SQL key sets equal the tag's" do
      for {fun, keys} <- [
            {"wallop_v6_lock_keys", LandObs.lock_keys()},
            {"wallop_v6_exec_keys", LandObs.exec_keys()}
          ] do
        assert %{rows: [[^keys]]} = Repo.query!("SELECT #{fun}()")
      end
    end

    test "an execution receipt with a key added, missing or nested is refused" do
      x = completed_v6_receipt_input(:observed)
      payload = x.input |> build() |> Jason.decode!()
      refused = "v6 execution receipt keys are not the tag's key set"

      for {label, tampered} <- [
            {"extra", Map.put(payload, "winner", "me")},
            {"missing", Map.delete(payload, "wallop_core_version")},
            {"nested", Map.put(payload, "extra", %{"seed" => payload["seed"]})}
          ] do
        assert insert_exec_receipt(Jason.encode!(tampered), x.cols) == refused, label
      end
    end

    test "a lock receipt with a key added, missing or nested is refused" do
      {_op, key} = create_v6_operator()
      s = in_time_schedule()
      d = open_draw_with_entries(key)
      assert raw_lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      assert insert_receipt(payload, cols) == nil
      refused = "v6 lock receipt keys are not the tag's key set"

      for {label, tampered} <- [
            {"extra", Map.put(payload, "prize", "a goat")},
            {"missing", Map.delete(payload, "wallop_core_version")},
            {"nested", Map.put(payload, "extra", %{"sequence" => payload["sequence"]})}
          ] do
        assert insert_receipt(tampered, cols) == refused, label
      end
    end
  end

  describe "the drand binding" do
    test "a real quicknet beacon's randomness is sha256 of its signature, in the guard's encoding" do
      # quicknet round 33068212.
      randomness = "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"

      signature =
        "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

      assert %{rows: [[^randomness]]} =
               Repo.query!("SELECT encode(sha256(decode($1, 'hex')), 'hex')", [signature])
    end

    test "an execution receipt whose randomness isn't sha256 of its signature is refused" do
      x = completed_v6_receipt_input(:fallback)

      for {label, randomness, signature} <- [
            {"another signature", x.input.drand_randomness, String.duplicate("ef", 48)},
            {"not hex", x.input.drand_randomness, "sig"},
            {"upper case", String.upcase(x.input.drand_randomness), x.input.drand_signature}
          ] do
        # The draw row carries the same pair, so only the binding can refuse.
        with_triggers_off(fn ->
          Repo.query!(
            "UPDATE draws SET drand_randomness = $2, drand_signature = $3 WHERE id = $1",
            [dump(x.draw.id), randomness, signature]
          )
        end)

        assert insert_exec_receipt(Jason.encode!(raw_payload(x, randomness, signature)), x.cols) ==
                 "v6 execution receipt drand_randomness is not sha256 of drand_signature",
               label
      end
    end
  end

  describe "the delete guard" do
    test "a v6 draw that has left open can't be deleted, in any status" do
      {_op, key} = create_v6_operator()

      awaiting =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(3600))

      pending =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(3600))

      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(pending.id)])

      # Failing is allowed before pub(R).
      failed =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(3600))

      Repo.query!("UPDATE draws SET status = 'failed' WHERE id = $1", [dump(failed.id)])

      completed = completed_v6_receipt_input(:fallback, api_key: key).draw

      for draw <- [awaiting, pending, failed, completed] do
        assert try_sql("DELETE FROM draws WHERE id = $1", [dump(draw.id)]) == @no_delete
      end

      # Its receipts are not what stops it: with them gone it is still refused.
      with_triggers_off(fn ->
        Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(awaiting.id)])
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(awaiting.id)]) == @no_delete
    end

    test "an open draw of an observation operator can still be deleted" do
      {_op, key} = create_v6_operator()
      draw = open_draw_with_entries(key)
      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(draw.id)]) == nil
    end

    test "forecast draws are deleted, or refused, exactly as before" do
      api_key = create_api_key()

      open =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(open.id)]) == nil

      # A locked forecast draw: its lock receipt's foreign key refuses, and
      # with the receipt gone the draw is deletable, as before.
      locked = create_draw(api_key)
      assert locked.status == :awaiting_entropy

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(locked.id)]) =~
               ~s(violates RESTRICT setting of foreign key constraint "operator_receipts_draw_id_fkey")

      with_triggers_off(fn ->
        Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(locked.id)])
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(locked.id)]) == nil

      done = create_draw(api_key)

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET status = 'completed' WHERE id = $1", [dump(done.id)])
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(done.id)]) ==
               "Cannot delete a completed draw"
    end
  end

  describe "the fallback grace in the completion guard" do
    test "after F but within a minute of it, the fallback is refused" do
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(30))) == @fallback_late
    end

    test "more than a minute after F, the fallback completes" do
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(90))) == nil
    end

    test "a stored reading completes within that minute: the grace is for the fallback only" do
      wt = wt_with_deadline_ago(30)
      draw = pending_v6(wt)
      put_observation!(Stations.primary().id, wt, @value)

      assert try_sql(
               "UPDATE draws SET status = 'completed', executed_at = $2, weather_value = $3, weather_observation_time = $4 WHERE id = $1",
               [dump(draw.id), NaiveDateTime.utc_now(), @value, DateTime.to_naive(wt)]
             ) == nil
    end
  end

  describe "under a non-UTC session" do
    # +13:45: a guard reading local time instead of UTC would let the early
    # fallback through and refuse the early fail.
    setup do
      Repo.query!("SET LOCAL TIME ZONE 'Pacific/Chatham'")
      :ok
    end

    test "the fallback grace holds on both guards" do
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(30))) == @fallback_late
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(90))) == nil

      early =
        completed_v6_receipt_input(:fallback,
          weather_time: wt_with_deadline_ago(30),
          triggers_off: true
        )

      assert insert_exec_receipt(build(early.input), early.cols) == @grace

      later = completed_v6_receipt_input(:fallback, weather_time: wt_with_deadline_ago(90))
      assert insert_exec_receipt(build(later.input), later.cols) == nil
    end

    test "failing is refused from F, allowed before it" do
      {_op, key} = create_v6_operator()
      fail = "UPDATE draws SET status = 'failed' WHERE id = $1"

      published =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(60), round_at(-10))

      assert try_sql(fail, [dump(published.id)]) ==
               "a v6 draw can't fail once its fetch deadline has passed"

      # Past F, its round still 6 seconds off.
      past_f =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(60), round_at(6))

      assert try_sql(fail, [dump(past_f.id)]) ==
               "a v6 draw can't fail once its fetch deadline has passed"

      ahead =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(600))

      assert try_sql(fail, [dump(ahead.id)]) == nil
    end
  end
end
