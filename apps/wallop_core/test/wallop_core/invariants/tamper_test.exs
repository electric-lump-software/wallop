defmodule WallopCore.Invariants.TamperTest do
  @moduledoc """
  The tamper harness: every signed lock v6 / execution v5 field must refuse
  tampering at some layer.

    * **Builders.** Generated valid inputs go through the real
      `Protocol.build_v6_lock_payload/1` and `build_v6_execution_payload/1`.
      Each signed field is then mutated one step at a time (±1 µs, ±1 round,
      ±1 hour, Wittering, another chain or tag, nil, a wrong type),
      and so are the pairs that must agree. Each mutation is either refused
      by the builder with its exact message, or classified:
        - `:same_bytes`: the builder signs exactly the base bytes (a whole
          float, which JCS renders as an integer);
        - `{:db, field}`: the builder can't see it; the lock receipt
          trigger must refuse it (checked against real locked draws below);
        - `{:verifier, field}`: a field the builder can't see and the
          database doesn't bind; `spec/vectors/proof-bundle-v6-tamper.json`
          must carry a case for it, which the Rust verifier refuses;
        - `{:producer, field}`: another valid value (a later
          `executed_at`). No offline check can tell it from the
          truth; only the producer, from the draw row, knows it, and the
          execution receipt trigger binds it to the row;
        - `{:no_layer, field}`: refused by no layer today. These are listed
          in `@no_layer_refuses` and reported, never silently accepted.
    * **Database.** Real v6 draws, locked in time on generated schedules,
      take a receipt built by the real builder (the positive control); every
      `{:db, field}` mutation is then refused with its exact message.
      Completed v6 draws (observed from Middle Wallop, or fallback) take
      the execution receipt the signer would build; every execution
      mutation the builder can't see (`{:verifier, _}`, `{:producer, _}`) is
      then refused by the execution receipt trigger with its exact message,
      except the informational `wallop_core_version`. Signed integers
      written as a float or an exponent are refused by both triggers.
    * **Raw SQL sequences.** The lock, the receipt and each attack, in every
      order, against the draws and `operator_receipts` triggers.
    * **The tamper vectors.** One file per entropy tag, each built from
      the tag's `WallopCore.TamperProfiles` module. Each committed file is
      what the generator writes, each case changes exactly one signed field
      and stays signed, and every signed field of each tag has a case or is
      listed as verifier-blind. The grid-frequency builder and database
      tables are in `WallopCore.Invariants.TamperFreqTest`.
  """
  use WallopCore.InvariantCase, async: false
  use ExUnitProperties

  @moduletag :invariant

  alias WallopCore.Drand.Quicknet
  alias WallopCore.ProofBundle
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.TamperProfiles
  alias WallopCore.TamperVectors
  alias WallopCore.Weather.{Schedule, Stations}

  @compile {:no_warn_undefined, [{ProofBundle, :assemble, 1}]}

  @hour_us 3_600_000_000
  @mainnet "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"
  @v2_tag "drand-quicknet+metoffice-landobs-v2"
  @other_hash String.duplicate("ab", 32)

  # Signed lock keys the receipt trigger binds to the draw row or the
  # receipt columns (see INV-2 in Group A).
  @db_bound ~w(commitment_hash drand_chain drand_round draw_id entropy_composition entry_hash
               locked_at operator_id operator_slug schema_version sequence signing_key_id
               weather_station weather_time winner_count)

  # Execution fields that only the producer can know: another valid value
  # is indistinguishable offline. The execution receipt trigger binds both.
  @producer_only ~w(executed_at)

  # Mutations no layer refuses today. Reported as findings. A change that
  # adds a check moves a field out of here.
  @no_layer_refuses %{lock: ~w(wallop_core_version), exec: ~w(wallop_core_version)}

  # Signed fields the Rust verifier does not check, so the tamper vector
  # can't carry a refusing case for them (a re-signed change passes).
  @verifier_blind %{lock: ~w(wallop_core_version), exec: ~w(wallop_core_version)}

  defp us(dt, n), do: DateTime.add(dt, n, :microsecond)
  defp hours(dt, n), do: DateTime.add(dt, n * 3600)

  defp same_hour?(round, wt),
    do: DateTime.compare(Schedule.weather_time_for_round(round), wt) == :eq

  # ── Generators ─────────────────────────────────────────────────────

  defp weather_value do
    gen all(
          t <- integer(-900..600),
          mslp <- integer(850..1100),
          rh <- integer(0..100),
          vis <- integer(0..10_000)
        ) do
      Enum.join([t, mslp, rh, vis], ";")
    end
  end

  # A valid lock v6 / execution v5 input pair: any round, `locked_at` at or
  # before the limit, `executed_at` at or after pub(R), observed (either
  # station) or fallback.
  defp v6_inputs do
    gen all(
          round <- integer(1_000_000..90_000_000),
          lock_back <- one_of([constant(0), integer(1..(4 * @hour_us))]),
          exec_after <- one_of([constant(0), integer(1..600_000_000)]),
          kind <- member_of([:observed, :fallback]),
          station <- member_of(Stations.ids()),
          value <- weather_value()
        ) do
      wt = Schedule.weather_time_for_round(round)
      pub = Quicknet.pub_time(round)

      lock = %{
        TamperVectors.lock_input()
        | drand_round: round,
          weather_time: wt,
          locked_at: us(Schedule.latest_lock_at(wt), -lock_back)
      }

      exec = %{
        TamperVectors.exec_input(kind, "")
        | drand_round: round,
          executed_at: us(pub, exec_after)
      }

      exec =
        if kind == :observed,
          do: %{
            exec
            | weather_station: station,
              weather_value: value,
              weather_observation_time: wt
          },
          else: exec

      %{
        lock: lock,
        exec: exec,
        kind: kind,
        round: round,
        wt: wt,
        lock_back: lock_back,
        exec_after: exec_after
      }
    end
  end

  # ── Mutation tables ────────────────────────────────────────────────

  defp tag_message(tag),
    do:
      "unknown entropy_composition for lock v6 / execution v5: #{inspect(tag)}; " <>
        "accepted: #{inspect(Protocol.v6_entropy_compositions())}"

  defp chain_message(chain),
    do:
      "lock v6 / execution v5 drand_chain must be the quicknet chain " <>
        "#{Quicknet.chain_hash()}, got: #{inspect(chain)}"

  # `{label, mutated_input, expected}` for every lock mutation of `c`.
  defp lock_mutations(%{lock: l, round: r, wt: wt, lock_back: back}) do
    obs_hour = &"lock v6 weather_time is not the observation hour for drand round #{&1}"
    late = "lock v6 locked_at is later than weather_time minus 46 minutes"
    whole = "lock v6 weather_time must be a whole UTC hour"
    station = "lock v6 weather_station must be #{Stations.primary().id}"
    positive = "lock v6 drand_round must be a positive integer"

    round_step = fn n ->
      if same_hour?(r + n, wt), do: {:db, "drand_round"}, else: {:raise, obs_hour.(r + n)}
    end

    late_unless = fn ok?, field -> if ok?, do: {:db, field}, else: {:raise, late} end

    invisible =
      for {key, value} <- [
            sequence: l.sequence + 1,
            sequence: l.sequence - 1,
            sequence: Integer.to_string(l.sequence),
            winner_count: l.winner_count + 1,
            winner_count: l.winner_count - 1,
            winner_count: Integer.to_string(l.winner_count),
            draw_id: Ecto.UUID.generate(),
            draw_id: String.upcase(l.draw_id),
            operator_id: Ecto.UUID.generate(),
            operator_slug: "someone-else",
            entry_hash: @other_hash,
            entry_hash: String.upcase(l.entry_hash),
            commitment_hash: @other_hash,
            signing_key_id: "deadbeef"
          ],
          do: {"#{key} = #{inspect(value)}", Map.put(l, key, value), {:db, Atom.to_string(key)}}

    nils =
      for key <- ~w(sequence winner_count draw_id operator_id operator_slug entry_hash
                    commitment_hash signing_key_id wallop_core_version fair_pick_version)a,
          do: {"#{key} nil", Map.put(l, key, nil), {:raise, "lock v6 #{key} must not be nil"}}

    [
      {"drand_round +1", %{l | drand_round: r + 1}, round_step.(1)},
      {"drand_round -1", %{l | drand_round: r - 1}, round_step.(-1)},
      {"drand_round +1h", %{l | drand_round: r + 1200}, {:raise, obs_hour.(r + 1200)}},
      {"drand_round -1h", %{l | drand_round: r - 1200}, {:raise, obs_hour.(r - 1200)}},
      {"drand_round nil", %{l | drand_round: nil},
       {:raise, "lock v6 drand_round must not be nil"}},
      {"drand_round string", %{l | drand_round: Integer.to_string(r)}, {:raise, positive}},
      {"drand_round 0", %{l | drand_round: 0}, {:raise, positive}},
      {"weather_time +1h", %{l | weather_time: hours(wt, 1)}, {:raise, obs_hour.(r)}},
      {"weather_time -1h", %{l | weather_time: hours(wt, -1)}, {:raise, obs_hour.(r)}},
      {"weather_time +1µs", %{l | weather_time: us(wt, 1)}, {:raise, whole}},
      {"weather_time -1µs", %{l | weather_time: us(wt, -1)}, {:raise, whole}},
      {"weather_time nil", %{l | weather_time: nil}, {:raise, whole}},
      {"weather_time string", %{l | weather_time: rfc(wt)}, {:raise, whole}},
      {"locked_at +1µs", %{l | locked_at: us(l.locked_at, 1)},
       late_unless.(back >= 1, "locked_at")},
      {"locked_at -1µs", %{l | locked_at: us(l.locked_at, -1)}, {:db, "locked_at"}},
      {"locked_at +1h", %{l | locked_at: hours(l.locked_at, 1)},
       late_unless.(back >= @hour_us, "locked_at")},
      {"locked_at -1h", %{l | locked_at: hours(l.locked_at, -1)}, {:db, "locked_at"}},
      {"locked_at nil", %{l | locked_at: nil}, {:raise, "lock v6 locked_at must not be nil"}},
      {"locked_at string", %{l | locked_at: rfc(l.locked_at)},
       {:raise, "lock v6 locked_at must be a DateTime"}},
      {"weather_station Wittering", %{l | weather_station: "wmo-03462"}, {:raise, station}},
      {"weather_station unlisted", %{l | weather_station: "wmo-03772"}, {:raise, station}},
      {"weather_station nil", %{l | weather_station: nil}, {:raise, station}},
      {"weather_station atom", %{l | weather_station: :"wmo-03749"}, {:raise, station}},
      {"drand_chain mainnet", %{l | drand_chain: @mainnet}, {:raise, chain_message(@mainnet)}},
      {"drand_chain upper case", %{l | drand_chain: String.upcase(l.drand_chain)},
       {:raise, chain_message(String.upcase(l.drand_chain))}},
      {"drand_chain nil", %{l | drand_chain: nil},
       {:raise, "lock v6 drand_chain must not be nil"}},
      {"entropy_composition forecast", %{l | entropy_composition: Protocol.entropy_composition()},
       {:raise, tag_message(Protocol.entropy_composition())}},
      {"entropy_composition v2", %{l | entropy_composition: @v2_tag},
       {:raise, tag_message(@v2_tag)}},
      {"entropy_composition nil", %{l | entropy_composition: nil}, {:raise, tag_message(nil)}},
      {"entropy_composition missing", Map.delete(l, :entropy_composition),
       {:raise, "lock v6 / execution v5 input must carry :entropy_composition"}},
      {"wallop_core_version other", %{l | wallop_core_version: "9.9.9"},
       {:no_layer, "wallop_core_version"}},
      {"fair_pick_version other", %{l | fair_pick_version: "9.9.9"},
       {:verifier, "fair_pick_version"}},
      # Floats: JCS renders a whole float as an integer, so the signed
      # bytes are unchanged; the round is refused outright.
      {"sequence 7.0", %{l | sequence: l.sequence * 1.0}, :same_bytes},
      {"winner_count float", %{l | winner_count: l.winner_count * 1.0}, :same_bytes},
      {"drand_round float", %{l | drand_round: r * 1.0}, {:raise, positive}},
      # Pairs that must agree.
      {"drand_round +1h with weather_time +1h",
       %{l | drand_round: r + 1200, weather_time: hours(wt, 1)}, {:db, "drand_round"}},
      {"drand_round -1h with weather_time -1h",
       %{l | drand_round: r - 1200, weather_time: hours(wt, -1)},
       late_unless.(back >= @hour_us, "drand_round")},
      {"weather_time +1h with locked_at +1h",
       %{l | weather_time: hours(wt, 1), locked_at: hours(l.locked_at, 1)},
       {:raise, obs_hour.(r)}},
      {"weather_time -1h with locked_at -1h",
       %{l | weather_time: hours(wt, -1), locked_at: hours(l.locked_at, -1)},
       {:raise, obs_hour.(r)}},
      {"all three +1h",
       %{
         l
         | drand_round: r + 1200,
           weather_time: hours(wt, 1),
           locked_at: hours(l.locked_at, 1)
       }, {:db, "locked_at"}}
    ] ++ invisible ++ nils
  end

  # `{label, mutated_input, expected}` for every execution mutation of `c`.
  defp exec_mutations(%{exec: e, kind: kind, round: r, wt: wt, exec_after: after_us}) do
    obs_hour = &exec_obs_hour/1
    before = &exec_before/1
    station = "exec v5 weather_station must be #{Stations.primary().id}"
    observed? = kind == :observed

    # A round n steps on: the observation hour must still match (observed),
    # and executed_at must not precede the new round's publication.
    round_step = fn n ->
      cond do
        observed? and not same_hour?(r + n, wt) -> {:raise, obs_hour.(r + n)}
        after_us < n * 3_000_000 -> {:raise, before.(r + n)}
        true -> {:verifier, "drand_round"}
      end
    end

    invisible =
      for {key, value} <- [
            sequence: e.sequence + 1,
            draw_id: Ecto.UUID.generate(),
            operator_id: Ecto.UUID.generate(),
            entry_hash: @other_hash,
            lock_receipt_hash: @other_hash,
            drand_randomness: @other_hash,
            drand_signature: String.duplicate("ab", 48),
            seed: @other_hash,
            results: Enum.reverse(e.results),
            signing_key_id: "deadbeef"
          ],
          do: {"#{key} = #{inspect(value)}", Map.put(e, key, value), {:verifier, "#{key}"}}

    nils =
      for key <- ~w(sequence draw_id operator_id operator_slug entry_hash lock_receipt_hash
                    drand_randomness drand_signature seed results signing_key_id
                    wallop_core_version fair_pick_version)a,
          do: {"#{key} nil", Map.put(e, key, nil), {:raise, "exec v5 #{key} must not be nil"}}

    common = [
      {"drand_round +1", %{e | drand_round: r + 1}, round_step.(1)},
      {"drand_round -1", %{e | drand_round: r - 1}, round_step.(-1)},
      {"drand_round +1h", %{e | drand_round: r + 1200},
       {:raise, if(observed?, do: obs_hour.(r + 1200), else: before.(r + 1200))}},
      {"drand_round nil", %{e | drand_round: nil},
       {:raise, "exec v5 drand_round must not be nil"}},
      {"drand_round string", %{e | drand_round: Integer.to_string(r)},
       {:raise, "exec v5 drand_round must be a positive integer"}},
      {"executed_at -1µs", %{e | executed_at: us(e.executed_at, -1)},
       if(after_us >= 1, do: {:producer, "executed_at"}, else: {:raise, before.(r)})},
      {"executed_at +1µs", %{e | executed_at: us(e.executed_at, 1)}, {:producer, "executed_at"}},
      {"executed_at pub(R) - 1µs", %{e | executed_at: us(Quicknet.pub_time(r), -1)},
       {:raise, before.(r)}},
      {"executed_at nil", %{e | executed_at: nil},
       {:raise, "exec v5 executed_at must not be nil"}},
      {"executed_at string", %{e | executed_at: rfc(e.executed_at)},
       {:raise, "exec v5 executed_at must be a DateTime"}},
      {"weather_station unlisted", %{e | weather_station: "wmo-03772"}, {:raise, station}},
      {"weather_station nil", %{e | weather_station: nil}, {:raise, station}},
      {"drand_chain mainnet", %{e | drand_chain: @mainnet}, {:raise, chain_message(@mainnet)}},
      {"drand_chain nil", %{e | drand_chain: nil},
       {:raise, "exec v5 drand_chain must not be nil"}},
      {"entropy_composition forecast", %{e | entropy_composition: Protocol.entropy_composition()},
       {:raise, tag_message(Protocol.entropy_composition())}},
      {"entropy_composition v2", %{e | entropy_composition: @v2_tag},
       {:raise, tag_message(@v2_tag)}},
      {"entropy_composition nil", %{e | entropy_composition: nil}, {:raise, tag_message(nil)}},
      {"operator_slug other", %{e | operator_slug: "someone-else"}, {:verifier, "operator_slug"}},
      {"sequence 7.0", %{e | sequence: e.sequence * 1.0}, :same_bytes},
      {"drand_round float", %{e | drand_round: r * 1.0},
       {:raise, "exec v5 drand_round must be a positive integer"}},
      {"wallop_core_version other", %{e | wallop_core_version: "9.9.9"},
       {:no_layer, "wallop_core_version"}},
      {"fair_pick_version other", %{e | fair_pick_version: "9.9.9"},
       {:verifier, "fair_pick_version"}}
    ]

    common ++ exec_weather_mutations(kind, e, r, wt) ++ invisible ++ nils
  end

  defp exec_obs_hour(round),
    do: "exec v5 weather_observation_time is not the observation hour for drand round #{round}"

  defp exec_before(round), do: "exec v5 executed_at is before drand round #{round} was published"

  @exec_fields ~s(exec v5 weather fields must be a value and observation time with a null reason, or both null with reason "no_observation_by_deadline")
  @exec_grammar "exec v5 weather_value does not match the Land Observations grammar and bounds"

  defp exec_weather_mutations(:observed, e, r, wt) do
    [t, mslp, rh, vis] = String.split(e.weather_value, ";")

    bumped =
      Enum.join([String.to_integer(t) + if(t == "600", do: -1, else: 1), mslp, rh, vis], ";")

    [
      {"weather_station Wittering", %{e | weather_station: "wmo-03462"},
       {:raise, "exec v5 weather_station must be #{Stations.primary().id}"}},
      {"weather_observation_time +1h", %{e | weather_observation_time: hours(wt, 1)},
       {:raise, exec_obs_hour(r)}},
      {"weather_observation_time -1h", %{e | weather_observation_time: hours(wt, -1)},
       {:raise, exec_obs_hour(r)}},
      {"weather_observation_time +1µs", %{e | weather_observation_time: us(wt, 1)},
       {:raise, "exec v5 weather_observation_time must be a whole UTC hour"}},
      {"weather_observation_time nil", %{e | weather_observation_time: nil},
       {:raise, @exec_fields}},
      {"weather_observation_time string", %{e | weather_observation_time: rfc(wt)},
       {:raise, @exec_fields}},
      {"weather_value one step off", %{e | weather_value: bumped}, {:verifier, "weather_value"}},
      {"weather_value off grammar", %{e | weather_value: "-0;1025;85;2432"},
       {:raise, @exec_grammar}},
      {"weather_value out of bounds", %{e | weather_value: "601;1025;85;2432"},
       {:raise, @exec_grammar}},
      {"weather_value nil", %{e | weather_value: nil}, {:raise, @exec_grammar}},
      {"weather_fallback_reason set", %{e | weather_fallback_reason: LandObs.fallback_reason()},
       {:raise, @exec_fields}},
      {"drand_round +1h with weather_observation_time +1h",
       %{e | drand_round: r + 1200, weather_observation_time: hours(wt, 1)},
       {:raise, exec_before(r + 1200)}}
    ]
  end

  defp exec_weather_mutations(:fallback, e, _r, wt) do
    [
      {"weather_station Wittering on a fallback", %{e | weather_station: "wmo-03462"},
       {:raise, "exec v5 weather_station must be #{Stations.primary().id}"}},
      {"weather_value set on a fallback", %{e | weather_value: "141;1025;85;2432"},
       {:raise, @exec_fields}},
      {"weather_observation_time set on a fallback", %{e | weather_observation_time: wt},
       {:raise, @exec_fields}},
      {"weather_fallback_reason schema 4", %{e | weather_fallback_reason: "unreachable"},
       {:raise, @exec_fields}},
      {"weather_fallback_reason nil", %{e | weather_fallback_reason: nil}, {:raise, @exec_fields}}
    ]
  end

  # The same instant as the UTC `dt`, as a Europe/London DateTime with a
  # `h`-hour offset (0 in winter, 1 in summer).
  defp london(%DateTime{time_zone: "Etc/UTC"} = dt, h) do
    %{
      DateTime.add(dt, h * 3600)
      | time_zone: "Europe/London",
        zone_abbr: if(h == 1, do: "BST", else: "GMT"),
        utc_offset: 0,
        std_offset: h * 3600
    }
  end

  defp build_lock(input), do: Protocol.build_v6_lock_payload(input)
  defp build_exec(input), do: Protocol.build_v6_execution_payload(input)

  # Asserts the builder outcome of one mutation; returns the payload when built.
  defp assert_builder(builder, base_jcs, {label, input, expected}, layer_fields) do
    base_payload = Jason.decode!(base_jcs)

    case expected do
      :same_bytes ->
        assert builder.(input) == base_jcs, label
        nil

      {:raise, message} ->
        error = assert_raise ArgumentError, fn -> builder.(input) end
        assert Exception.message(error) == message, label
        nil

      {layer, field} ->
        payload = Jason.decode!(builder.(input))

        refute payload[field] == base_payload[field],
               "#{label}: the mutation did not reach the signed bytes"

        assert field in Map.fetch!(layer_fields, layer),
               "#{label}: #{field} is not a #{layer} field"

        payload
    end
  end

  defp vector_fields(receipt) do
    for {_, _, r, field, _, _, _} <- TamperVectors.cases(),
        r in [receipt, :both],
        uniq: true,
        do: field
  end

  # ── Builders ───────────────────────────────────────────────────────

  describe "INV-2 the builders refuse every one-step lock and execution mutation they can see" do
    property "INV-2 (tamper, lock builder) each mutation is refused, or left to the database" do
      check all(c <- v6_inputs(), max_runs: 200) do
        base = build_lock(c.lock)

        for m <- lock_mutations(c) do
          assert_builder(&build_lock/1, base, m, %{
            db: @db_bound,
            verifier: vector_fields(:lock),
            no_layer: @no_layer_refuses.lock
          })
        end
      end
    end

    property "INV-2 (tamper, exec builder) each mutation is refused, or left to the verifier" do
      check all(c <- v6_inputs(), max_runs: 200) do
        base = build_exec(c.exec)

        for m <- exec_mutations(c) do
          assert_builder(&build_exec/1, base, m, %{
            verifier: vector_fields(:exec),
            producer: @producer_only,
            no_layer: @no_layer_refuses.exec
          })
        end
      end
    end

    test "INV-2 (tamper) the builders refuse a signed time in UK time, in winter (+00:00) and summer (+01:00)" do
      freq_lock = TamperVectors.lock_input(TamperProfiles.Freq)
      {freq_lock_jcs, _} = TamperVectors.base(TamperProfiles.Freq, :observed)
      lock = TamperVectors.lock_input()
      exec = TamperVectors.exec_input(:observed, build_lock(lock))
      freq_exec = TamperVectors.exec_input(TamperProfiles.Freq, :observed, freq_lock_jcs)

      for {builder, input, fields} <- [
            {&build_lock/1, lock, [:locked_at, :weather_time]},
            {&build_lock/1, freq_lock, [:locked_at, :freq_start]},
            {&build_exec/1, exec, [:executed_at, :weather_observation_time]},
            {&build_exec/1, freq_exec, [:executed_at]}
          ],
          field <- fields,
          h <- [0, 1] do
        uk = london(Map.fetch!(input, field), h)
        assert DateTime.compare(uk, Map.fetch!(input, field)) == :eq

        # Refused either by the schedule arithmetic (core runs with the
        # UTC-only time zone database) or, failing that, by the canonical
        # serialiser's non-UTC check. Never signed.
        assert_raise ArgumentError,
                     ~r/non-UTC DateTime|Calendar\.UTCOnlyTimeZoneDatabase/,
                     fn -> builder.(Map.put(input, field, uk)) end
      end
    end

    test "INV-2 (tamper) the lock tag and the execution tag must both be the Land Obs tag" do
      lock = TamperVectors.lock_input()
      lock_jcs = build_lock(lock)
      exec = TamperVectors.exec_input(:observed, lock_jcs)
      assert is_binary(build_exec(exec))

      for tag <- [Protocol.entropy_composition(), @v2_tag] do
        assert_raise ArgumentError, tag_message(tag), fn ->
          build_exec(%{exec | entropy_composition: tag})
        end

        assert_raise ArgumentError, tag_message(tag), fn ->
          build_lock(%{lock | entropy_composition: tag})
        end
      end
    end
  end

  # ── Database ───────────────────────────────────────────────────────

  @mismatch "v6 lock receipt field ~s does not match the draw"

  defp db_message("locked_at"), do: "receipt locked_at must equal the signed locked_at"
  defp db_message(field), do: :io_lib.format(@mismatch, [field]) |> IO.iodata_to_binary()

  # Builder input and receipt columns for `draw`, locked under `s`, signed
  # at `locked_at`, exactly as `valid_receipt/3` builds them.
  defp db_inputs(draw, s, locked_at) do
    {payload, cols} = valid_receipt(draw, s, locked_at)

    lock = %{
      entropy_composition: payload["entropy_composition"],
      operator_id: payload["operator_id"],
      operator_slug: payload["operator_slug"],
      sequence: payload["sequence"],
      draw_id: payload["draw_id"],
      commitment_hash: payload["commitment_hash"],
      entry_hash: payload["entry_hash"],
      locked_at: locked_at,
      signing_key_id: payload["signing_key_id"],
      winner_count: payload["winner_count"],
      drand_chain: payload["drand_chain"],
      drand_round: payload["drand_round"],
      weather_station: payload["weather_station"],
      weather_time: s.weather_time,
      wallop_core_version: payload["wallop_core_version"],
      fair_pick_version: payload["fair_pick_version"]
    }

    assert Jason.decode!(build_lock(lock)) == payload
    {lock, cols}
  end

  defp schedule_ahead(s, hours) do
    {:ok, ahead} = Schedule.schedule(Quicknet.pub_time(s.round + hours * 1200))
    ahead
  end

  describe "INV-2 the receipt trigger refuses every lock mutation the builder can't see" do
    setup do
      {operator, key} = create_v6_operator()
      # The operator's key is in the keyring from here: every generated
      # locked_at is at or after this instant.
      %{key: key, operator: operator, t0: DateTime.utc_now(), s: in_time_schedule()}
    end

    property "INV-2 (tamper, database) each builder-invisible mutation is refused, with a positive control",
             %{key: key, t0: t0, s: s0} do
      check all(
              ahead <- integer(0..5),
              frac <- one_of([constant(0), constant(1000), integer(0..1000)]),
              max_runs: 15
            ) do
        s = schedule_ahead(s0, ahead)
        span = DateTime.diff(s.latest_lock_at, t0, :microsecond)
        locked_at = us(t0, div(span * frac, 1000))

        d = open_draw_with_entries(key)
        assert raw_lock(d, s.weather_time, s.round) == nil
        {lock, cols} = db_inputs(d, s, locked_at)

        c = %{
          lock: lock,
          round: s.round,
          wt: s.weather_time,
          lock_back: DateTime.diff(s.latest_lock_at, locked_at, :microsecond)
        }

        # Positive control: the real builder's receipt is accepted.
        assert insert_receipt(Jason.decode!(build_lock(lock)), cols) == nil

        for {label, input, expected} <- lock_mutations(c) do
          case expected do
            {:db, field} ->
              assert insert_receipt(Jason.decode!(build_lock(input)), cols) == db_message(field),
                     label

            {layer, field} when layer in [:no_layer, :verifier] ->
              # Unbound in the database: the build constants.
              assert field in (@no_layer_refuses.lock ++ vector_fields(:lock))
              assert insert_receipt(Jason.decode!(build_lock(input)), cols) == nil, label

            {:raise, _} ->
              :builder

            :same_bytes ->
              :builder
          end
        end
      end
    end

    test "INV-2 (tamper, database) mutations the builder refuses are refused by the trigger too",
         %{key: key, s: s} do
      d = open_draw_with_entries(key)
      assert raw_lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      assert insert_receipt(payload, cols) == nil

      late = us(s.latest_lock_at, 1)
      pair = "a v6 lock receipt must carry its draw's schema and entropy_composition"

      for {label, tampered, tampered_cols, message} <- [
            {"station", %{payload | "weather_station" => "wmo-03462"}, cols,
             db_message("weather_station")},
            {"chain", %{payload | "drand_chain" => @mainnet}, cols, db_message("drand_chain")},
            {"round +1h", %{payload | "drand_round" => s.round + 1200}, cols,
             db_message("drand_round")},
            {"weather_time +1h", %{payload | "weather_time" => rfc(hours(s.weather_time, 1))},
             cols, db_message("weather_time")},
            {"weather_time +1µs", %{payload | "weather_time" => rfc(us(s.weather_time, 1))}, cols,
             db_message("weather_time")},
            {"weather_time with an offset",
             %{payload | "weather_time" => String.replace(rfc(s.weather_time), "Z", "+00:00")},
             cols,
             "not a canonical UTC timestamp: " <>
               String.replace(rfc(s.weather_time), "Z", "+00:00")},
            {"weather_time at +01:00",
             %{payload | "weather_time" => offset_rfc(s.weather_time, 1)}, cols,
             not_canonical(offset_rfc(s.weather_time, 1))},
            {"locked_at with an offset",
             %{payload | "locked_at" => offset_rfc(cols.locked_at, 0)}, cols,
             not_canonical(offset_rfc(cols.locked_at, 0))},
            {"locked_at at +01:00", %{payload | "locked_at" => offset_rfc(cols.locked_at, 1)},
             cols, not_canonical(offset_rfc(cols.locked_at, 1))},
            {"tag v2", %{payload | "entropy_composition" => @v2_tag}, cols, pair},
            {"schema 5", %{payload | "schema_version" => "5"}, cols, pair},
            {"round and weather_time +1h together",
             %{
               payload
               | "drand_round" => s.round + 1200,
                 "weather_time" => rfc(hours(s.weather_time, 1))
             }, cols, db_message("drand_round")},
            {"weather_time and locked_at +1h together",
             %{
               payload
               | "weather_time" => rfc(hours(s.weather_time, 1)),
                 "locked_at" => rfc(hours(cols.locked_at, 1))
             }, %{cols | locked_at: hours(cols.locked_at, 1)}, db_message("weather_time")},
            {"locked_at late, column too", %{payload | "locked_at" => rfc(late)},
             %{cols | locked_at: late}, "v6 signed locked_at is too late for this draw time"},
            {"locked_at before the key",
             %{payload | "locked_at" => rfc(hours(cols.locked_at, -1))},
             %{cols | locked_at: hours(cols.locked_at, -1)},
             "v6 lock receipt signing key was not valid at locked_at"}
          ] do
        assert insert_receipt(tampered, tampered_cols) == message, label
      end
    end
  end

  # A signed integer written another way in the bytes: a whole float, or
  # an exponent (which jsonb reads back as the plain integer).
  @non_canonical [".0", ".00", "e0", "E0"]

  defp retype(json, field, n, form) do
    tampered = String.replace(json, ~s("#{field}":#{n}), ~s("#{field}":#{n}#{form}))
    refute tampered == json
    tampered
  end

  describe "INV-2 the receipt triggers and non-canonical integers" do
    setup do
      {_operator, key} = create_v6_operator()
      %{key: key, s: in_time_schedule()}
    end

    # jsonb compares 7.0 equal to 7, so the triggers type the signed
    # integers: a JSON number whose text is a canonical positive integer,
    # in the bytes too. The builder never signs anything else (JCS renders
    # a whole float as an integer) and the verifier refuses it (the tamper
    # vector's *_float cases).
    test "INV-2 (tamper, database) a lock receipt integer written as a float or an exponent is refused",
         %{key: key, s: s} do
      d = open_draw_with_entries(key)
      assert raw_lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      json = Jason.encode!(payload)
      assert insert_receipt_json(json, cols) == nil

      for field <- ~w(sequence winner_count drand_round), form <- @non_canonical do
        assert insert_receipt_json(retype(json, field, payload[field], form), cols) ==
                 "v6 lock receipt field #{field} must be a canonical positive integer",
               "#{field}#{form}"
      end
    end

    test "INV-2 (tamper, database) an execution receipt integer written as a float or an exponent is refused" do
      for kind <- [:observed, :fallback] do
        x = completed_v6_receipt_input(kind, hours_ago: if(kind == :observed, do: 2, else: 3))
        json = build_exec(x.input)
        assert insert_exec_receipt(json, x.cols) == nil, "#{kind}"

        for field <- ~w(sequence drand_round), form <- @non_canonical do
          assert insert_exec_receipt(
                   retype(json, field, x.input[String.to_atom(field)], form),
                   x.cols
                 ) ==
                   "v6 execution receipt field #{field} must be a canonical positive integer",
                 "#{kind} #{field}#{form}"
        end
      end
    end
  end

  # ── Database: the execution receipt ───────────────────────────────

  @exec_weather ~w(weather_station weather_value weather_observation_time weather_fallback_reason)

  defp exec_db_message(field) when field in @exec_weather,
    do: "v6 execution receipt field #{field} does not match the stored observation"

  defp exec_db_message(field), do: "v6 execution receipt field #{field} does not match the draw"

  # Signed execution fields the trigger leaves alone: informational only.
  @exec_db_unbound ~w(wallop_core_version)

  describe "INV-2 the execution receipt trigger refuses every execution mutation the builder can't see" do
    setup do
      {_operator, key} = create_v6_operator()
      %{key: key}
    end

    property "INV-2 (tamper, database) each builder-invisible execution mutation is refused, with a positive control",
             %{key: key} do
      check all(
              kind <- member_of([:observed, :fallback]),
              station <- member_of(Stations.ids()),
              value <- weather_value(),
              max_runs: 12
            ) do
        # An hour of its own for each run: one reading per hour.
        hours_ago = 24 + System.unique_integer([:positive, :monotonic])

        x =
          completed_v6_receipt_input(kind,
            api_key: key,
            station: station,
            value: value,
            hours_ago: hours_ago
          )

        c = %{exec: x.input, kind: kind, round: x.round, wt: x.wt, exec_after: x.exec_after}

        # Positive control: the real builder's receipt for the draw.
        assert insert_exec_receipt(build_exec(x.input), x.cols) == nil

        for {label, input, expected} <- exec_mutations(c) do
          case expected do
            {layer, field} when layer in [:verifier, :producer, :no_layer] ->
              expected = if field in @exec_db_unbound, do: nil, else: exec_db_message(field)
              assert insert_exec_receipt(build_exec(input), x.cols) == expected, label

            {:raise, _} ->
              :builder

            :same_bytes ->
              :builder
          end
        end
      end
    end

    test "INV-2 (tamper, database) mutations the builder refuses, and the receipt columns, are refused by the trigger too" do
      x = completed_v6_receipt_input(:observed, hours_ago: 4)
      payload = x.input |> build_exec() |> Jason.decode!()
      cols = x.cols
      pair = "a v6 execution receipt must be schema 5 and carry its draw's entropy_composition"
      before = rfc(DateTime.add(Quicknet.pub_time(x.round), -1, :microsecond))
      forecast = create_draw(create_api_key())

      for {label, tampered, tampered_cols, message} <- [
            {"schema 4", %{payload | "schema_version" => "4"}, cols, pair},
            {"forecast tag", %{payload | "entropy_composition" => Protocol.entropy_composition()},
             cols, pair},
            {"v2 tag", %{payload | "entropy_composition" => @v2_tag}, cols, pair},
            {"executed_at before pub(R)", %{payload | "executed_at" => before}, cols,
             exec_db_message("executed_at")},
            {"executed_at with an offset",
             %{payload | "executed_at" => offset_rfc(x.input.executed_at, 0)}, cols,
             not_canonical(offset_rfc(x.input.executed_at, 0))},
            {"executed_at at +01:00",
             %{payload | "executed_at" => offset_rfc(x.input.executed_at, 1)}, cols,
             not_canonical(offset_rfc(x.input.executed_at, 1))},
            {"weather_observation_time with an offset",
             %{
               payload
               | "weather_observation_time" => offset_rfc(x.input.weather_observation_time, 0)
             }, cols, not_canonical(offset_rfc(x.input.weather_observation_time, 0))},
            {"weather_observation_time at +01:00",
             %{
               payload
               | "weather_observation_time" => offset_rfc(x.input.weather_observation_time, 1)
             }, cols, not_canonical(offset_rfc(x.input.weather_observation_time, 1))},
            {"station unlisted", %{payload | "weather_station" => "wmo-03772"}, cols,
             exec_db_message("weather_station")},
            {"reading with a fallback reason",
             %{payload | "weather_fallback_reason" => LandObs.fallback_reason()}, cols,
             exec_db_message("weather_fallback_reason")},
            {"the fallback, with a reading stored",
             %{
               payload
               | "weather_value" => nil,
                 "weather_observation_time" => nil,
                 "weather_fallback_reason" => LandObs.fallback_reason()
             }, cols, exec_db_message("weather_value")},
            {"column sequence", payload, %{cols | sequence: cols.sequence + 1},
             exec_db_message("sequence")},
            {"column operator_id", payload, %{cols | operator_id: Ecto.UUID.generate()},
             exec_db_message("operator_id")},
            {"column lock_receipt_hash", payload, %{cols | lock_receipt_hash: @other_hash},
             exec_db_message("lock_receipt_hash")},
            {"column signing_key_id", payload, %{cols | signing_key_id: "deadbeef"},
             exec_db_message("signing_key_id")},
            {"another (forecast) draw", payload, %{cols | draw_id: forecast.id},
             "a schema 5 execution receipt needs a draw locked under schema 6"}
          ] do
        assert insert_exec_receipt(Jason.encode!(tampered), tampered_cols) == message, label
      end
    end
  end

  # ── Raw SQL attack sequences ──────────────────────────────────────

  @needs_lock "a schema 6 lock receipt needs a draw locked under schema 6"
  @duplicate ~s(duplicate key value violates unique constraint "operator_receipts_operator_id_sequence_index")
  @declared "Cannot modify declared entropy fields"
  @frozen "lock_schema_version and entropy_composition are frozen once a draw has left open"
  @set_only "lock_schema_version and entropy_composition are set only when a draw leaves open"
  @append_only "operator_receipts is append-only"
  @no_delete "a v6 draw can't be deleted once it has left open"
  @no_truncate "operator_receipts cannot be TRUNCATEd — use row-level DELETE with appropriate permissions"

  @attacks ~w(receipt2 update_round update_weather_time update_station update_chain
              update_pair reopen delete_receipt delete_draw truncate_receipts)a

  # Runs `sql` in a savepoint, kept when accepted. Returns nil or the refusal.
  defp keep_sql(sql, params) do
    Repo.transaction(fn -> Repo.query!(sql, params) end)
    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  defp receipt_sql(payload, cols) do
    keep_sql(
      """
      INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
        entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $7)
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(cols.operator_id),
        dump(cols.draw_id),
        cols.sequence,
        cols.commitment_hash,
        cols.entry_hash,
        DateTime.to_naive(cols.locked_at),
        cols.signing_key_id,
        Jason.encode!(payload),
        :binary.copy(<<0>>, 64)
      ]
    )
  end

  # Runs one step against `d` and returns `{refusal | nil, expected, state}`.
  defp step(:lock, d, ctx, st) do
    {raw_lock(d, ctx.s.weather_time, ctx.s.round), nil, %{st | locked: st.exists}}
  end

  defp step(name, d, ctx, st) when name in [:receipt, :receipt2] do
    {payload, cols} = ctx.receipt

    {expected, st} =
      cond do
        st.locked and not st.receipt -> {nil, %{st | receipt: true}}
        st.locked -> {@duplicate, st}
        true -> {@needs_lock, st}
      end

    _ = d
    {receipt_sql(payload, cols), expected, st}
  end

  defp step(name, d, _ctx, st)
       when name in [:update_round, :update_weather_time, :update_station, :update_chain] do
    {set, params} =
      case name do
        :update_round -> {"drand_round = drand_round + 1", []}
        :update_weather_time -> {"weather_time = weather_time + interval '1 hour'", []}
        :update_station -> {"weather_station = $2", ["wmo-03462"]}
        :update_chain -> {"drand_chain = $2", [@mainnet]}
      end

    expected = if st.locked, do: @declared
    {keep_sql("UPDATE draws SET #{set} WHERE id = $1", [dump(d.id) | params]), expected, st}
  end

  defp step(:update_pair, d, _ctx, st) do
    expected =
      cond do
        st.locked -> @frozen
        st.exists -> @set_only
        true -> nil
      end

    {keep_sql("UPDATE draws SET entropy_composition = $2 WHERE id = $1", [dump(d.id), @v2_tag]),
     expected, st}
  end

  defp step(:reopen, d, _ctx, st) do
    expected = if st.locked, do: @set_only
    {keep_sql("UPDATE draws SET status = 'open' WHERE id = $1", [dump(d.id)]), expected, st}
  end

  defp step(:delete_receipt, d, _ctx, st) do
    expected = if st.receipt, do: @append_only
    {keep_sql("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(d.id)]), expected, st}
  end

  defp step(:delete_draw, d, _ctx, st) do
    # A v6 draw that has left open can't be deleted, with or without its
    # receipt; the receipt's foreign key RESTRICT is behind that.
    {expected, st} =
      if st.locked,
        do: {@no_delete, st},
        else: {nil, %{st | exists: false, locked: false}}

    {keep_sql("DELETE FROM draws WHERE id = $1", [dump(d.id)]), expected, st}
  end

  defp step(:truncate_receipts, _d, _ctx, st) do
    {keep_sql("TRUNCATE operator_receipts", []), @no_truncate, st}
  end

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  defp assert_final_state(d, ctx, st, order) do
    rows =
      Repo.query!(
        """
        SELECT status, lock_schema_version, entropy_composition, drand_round, weather_time,
          weather_station, drand_chain FROM draws WHERE id = $1
        """,
        [dump(d.id)]
      ).rows

    receipts =
      Repo.query!("SELECT payload_jcs FROM operator_receipts WHERE draw_id = $1", [dump(d.id)]).rows

    s = ctx.s

    cond do
      not st.exists ->
        assert rows == [], inspect(order)

      st.locked ->
        assert rows == [
                 [
                   "awaiting_entropy",
                   "6",
                   LandObs.tag(),
                   s.round,
                   DateTime.to_naive(s.weather_time),
                   Stations.primary().id,
                   Quicknet.chain_hash()
                 ]
               ],
               inspect(order)

      true ->
        assert [["open", nil, nil | _]] = rows, inspect(order)
    end

    {payload, _} = ctx.receipt
    expected = if st.receipt, do: [[Jason.encode!(payload)]], else: []
    assert receipts == expected, inspect(order)
  end

  describe "INV-1 raw SQL: the lock, the receipt and each attack, in every order" do
    setup do
      {_operator, key} = create_v6_operator()
      %{key: key, s: in_time_schedule()}
    end

    test "INV-1 (raw SQL sequences) every order leaves one in-time lock and at most one valid receipt",
         %{key: key, s: s} do
      for attack <- @attacks, order <- permutations([:lock, :receipt, attack]) do
        d = open_draw_with_entries(key)
        ctx = %{s: s, receipt: valid_receipt(d, s)}

        st =
          Enum.reduce(order, %{exists: true, locked: false, receipt: false}, fn name, st ->
            {got, expected, st} = step(name, d, ctx, st)
            assert got == expected, "#{inspect(order)} at #{name}: #{inspect(got)}"
            st
          end)

        assert_final_state(d, ctx, st, order)
      end
    end

    test "INV-1 (raw SQL sequences) a draw inserted already locked is refused, before or after a receipt attempt",
         %{key: key, s: s} do
      [late | _] = missed_schedules()

      for sched <- [s, late], receipt_first? <- [true, false] do
        d = open_draw_with_entries(key)
        id = Ecto.UUID.generate()
        {payload, cols} = valid_receipt(d, s)
        copy = %{payload | "draw_id" => id}

        insert = fn ->
          {hash, canonical} = entry_hash(d)

          keep_sql(
            """
            INSERT INTO draws (id, status, winner_count, entry_count, api_key_id,
              operator_id, operator_sequence, stage_timestamps, inserted_at, updated_at,
              lock_schema_version, entropy_composition, drand_chain, drand_round,
              weather_time, weather_station, entry_hash, entry_canonical)
            SELECT $2, 'awaiting_entropy', winner_count, entry_count, api_key_id,
              operator_id, operator_sequence + 100000, stage_timestamps, inserted_at,
              updated_at, '6', $3, $4, $5, $6, $7, $8, $9
            FROM draws WHERE id = $1
            """,
            [
              dump(d.id),
              dump(id),
              LandObs.tag(),
              Quicknet.chain_hash(),
              sched.round,
              DateTime.to_naive(sched.weather_time),
              Stations.primary().id,
              hash,
              canonical
            ]
          )
        end

        receipt = fn -> receipt_sql(copy, %{cols | draw_id: id}) end

        results =
          if receipt_first?,
            do: [receipt.(), insert.()],
            else: [insert.(), receipt.()]

        expected =
          if receipt_first?,
            do: [@needs_lock, @set_only],
            else: [@set_only, @needs_lock]

        assert results == expected, inspect({sched.weather_time, receipt_first?})
        assert Repo.query!("SELECT 1 FROM draws WHERE id = $1", [dump(id)]).rows == []
      end
    end
  end

  # ── The tamper vectors ─────────────────────────────────────────────

  defp vector(profile),
    do: profile |> TamperVectors.path() |> File.read!() |> Jason.decode!()

  defp receipts(bundle_jcs) do
    b = Jason.decode!(bundle_jcs)

    {b, Jason.decode!(b["lock_receipt"]["payload_jcs"]),
     Jason.decode!(b["execution_receipt"]["payload_jcs"])}
  end

  # Strict, so 7.0 in place of 7 counts as a change.
  defp changed(a, b), do: for({k, v} <- a, b[k] !== v, do: k) |> Enum.sort()

  defp verified?(wrapper, key_hex) do
    Protocol.verify_receipt(
      wrapper["payload_jcs"],
      Base.decode16!(wrapper["signature_hex"], case: :lower),
      Base.decode16!(key_hex, case: :lower)
    )
  end

  describe "INV-2 the tamper vectors" do
    test "INV-2 (tamper vectors) the committed file is what the generator writes" do
      for profile <- TamperVectors.profiles() do
        assert File.read!(TamperVectors.path(profile)) == TamperVectors.encode(profile),
               profile.tag()
      end
    end

    test "INV-2 (tamper vectors) the bases come from the real builders on a real round published after the lock" do
      assert DateTime.compare(Quicknet.pub_time(TamperVectors.round()), TamperVectors.locked_at()) ==
               :gt

      for profile <- TamperVectors.profiles() do
        assert DateTime.compare(Quicknet.pub_time(TamperVectors.round()), profile.locked_at()) ==
                 :gt,
               profile.tag()

        for base <- vector(profile)["bases"] do
          {lock_jcs, exec_jcs} = TamperVectors.base_by_name(base["name"])
          {_, lock, exec} = receipts(base["bundle"])
          assert Jcs.encode(lock) == lock_jcs
          assert Jcs.encode(exec) == exec_jcs
          assert lock["entropy_composition"] == profile.tag()
          assert exec["entropy_composition"] == profile.tag()

          assert exec["lock_receipt_hash"] ==
                   :crypto.hash(:sha256, lock_jcs) |> Base.encode16(case: :lower)
        end
      end
    end

    test "INV-2 (tamper vectors) each case changes one signed field of one receipt and stays signed" do
      for profile <- TamperVectors.profiles() do
        v = vector(profile)
        [op, infra] = v["keys"]
        assert {op["key_class"], infra["key_class"]} == {"operator", "infrastructure"}
        bases = Map.new(v["bases"], &{&1["name"], receipts(&1["bundle"])})

        for case <- v["cases"] do
          {envelope, lock, exec} = receipts(case["bundle"])
          {base_envelope, base_lock, base_exec} = Map.fetch!(bases, case["base"])
          name = case["name"]

          assert verified?(envelope["lock_receipt"], op["public_key_hex"]), name
          assert verified?(envelope["execution_receipt"], infra["public_key_hex"]), name

          assert Map.drop(envelope, ~w(lock_receipt execution_receipt)) ==
                   Map.drop(base_envelope, ~w(lock_receipt execution_receipt)),
                 name

          case case["receipt"] do
            "lock" ->
              assert changed(lock, base_lock) == [case["field"]], name
              assert changed(exec, base_exec) == ["lock_receipt_hash"], name

              assert exec["lock_receipt_hash"] ==
                       :crypto.hash(:sha256, envelope["lock_receipt"]["payload_jcs"])
                       |> Base.encode16(case: :lower),
                     name

            "exec" ->
              assert lock == base_lock, name
              assert changed(exec, base_exec) == [case["field"]], name

            "both" ->
              assert changed(lock, base_lock) == [case["field"]], name

              assert changed(exec, base_exec) == Enum.sort([case["field"], "lock_receipt_hash"]),
                     name
          end

          assert case["expected_failing_steps"] != [], name
        end
      end
    end

    test "INV-2 (tamper vectors) every signed field has a refusing case, or is verifier-blind" do
      for profile <- TamperVectors.profiles() do
        names = Enum.map([:observed, :fallback], &profile.base_name/1)
        own = Enum.filter(vector(profile)["cases"], &(&1["base"] in names))
        assert own != [], profile.tag()

        for {receipt, keys} <- [lock: profile.lock_keys(), exec: profile.exec_keys()],
            key <- keys do
          covered? =
            Enum.any?(own, &(&1["receipt"] in ["#{receipt}", "both"] and &1["field"] == key))

          blind? = key in Map.fetch!(@verifier_blind, receipt)

          assert covered? != blind?,
                 "#{profile.tag()} #{receipt}.#{key}: covered #{covered?}, blind #{blind?}"
        end
      end

      # A verifier-blind lock field is refused by the database or listed
      # as refused by no layer. On the execution receipt the only one is
      # wallop_core_version, which the database leaves alone too.
      for key <- @verifier_blind.lock,
          do: assert(key in @db_bound or key in @no_layer_refuses.lock, key)

      assert @verifier_blind.exec == @no_layer_refuses.exec
    end

    test "INV-2 (tamper vectors) every grid-frequency signed field the Land Obs tag lacks, and every weather field it must keep null, is refused" do
      cases = vector(TamperProfiles.Freq)["cases"]

      tampered =
        for c <- cases, c["receipt"] in ["exec", "both"], do: c["field"], uniq: true

      for field <- ~w(freq_value freq_fallback_reason weather_station weather_value
                      weather_observation_time weather_fallback_reason entropy_composition),
          do: assert(field in tampered, "exec.#{field}")

      tampered = for c <- cases, c["receipt"] in ["lock", "both"], do: c["field"], uniq: true

      for field <- ~w(freq_start locked_at drand_round weather_station weather_time
                      entropy_composition),
          do: assert(field in tampered, "lock.#{field}")
    end

    test "INV-2 (tamper vectors) the Land Obs bases and cases are unchanged by the profile split" do
      landobs = TamperProfiles.LandObs
      v = vector(landobs)

      assert Enum.map(v["bases"], & &1["name"]) == ~w(observed fallback)
      names = Enum.map(landobs.cases(), fn {n, _, _, f, _, _, _} -> {n, f} end)

      for c <- v["cases"] do
        assert c["base"] in ~w(observed fallback), c["name"]
        assert {c["name"], c["field"]} in names, c["name"]
      end

      assert length(v["cases"]) == length(landobs.cases())
    end

    @tag :pending_task_13
    test "INV-2 (tamper vectors) each base bundle is the bytes ProofBundle.assemble/1 produces" do
      for profile <- TamperVectors.profiles(), base <- vector(profile)["bases"] do
        {envelope, _, _} = receipts(base["bundle"])

        assembled =
          ProofBundle.assemble(%{
            draw_id: envelope["draw_id"],
            entries: envelope["entries"],
            results: envelope["results"],
            entropy: envelope["entropy"],
            lock_receipt:
              {envelope["lock_receipt"]["payload_jcs"],
               Base.decode16!(envelope["lock_receipt"]["signature_hex"], case: :lower)},
            execution_receipt:
              {envelope["execution_receipt"]["payload_jcs"],
               Base.decode16!(envelope["execution_receipt"]["signature_hex"], case: :lower)},
            inline_keys: %{lock: nil, exec: nil}
          })

        assert assembled == base["bundle"], base["name"]
      end
    end
  end
end
