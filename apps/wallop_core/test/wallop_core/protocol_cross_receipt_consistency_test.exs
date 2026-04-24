defmodule WallopCore.ProtocolCrossReceiptConsistencyTest do
  @moduledoc """
  Producer-side invariants for the cross-receipt field consistency rule
  in `spec/protocol.md` §4.2.5.

  Verifiers are the ultimate enforcement point — these tests document
  the Elixir producer's side of the contract: that every lock/exec
  receipt pair emitted by `WallopCore.Protocol` for a single draw
  carries byte-identical values for the six cross-checked fields
  (`draw_id`, `operator_id`, `sequence`, `drand_chain`,
  `drand_round`, `weather_station`), and that `exec.weather_observation_time`
  falls in the `[lock.weather_time, lock.weather_time + 3600s]`
  window.

  These are Elixir-side property assertions, not splice-attack
  simulations — the Rust verifier carries the attack-simulation
  catalog (see `wallop_verifier/src/catalog/scenarios.json`).
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  @lock_input %{
    commitment_hash: "c0",
    draw_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    entry_hash: "e1",
    locked_at: ~U[2026-04-09 13:00:00.000000Z],
    operator_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    operator_slug: "acme-prizes",
    sequence: 42,
    signing_key_id: "beefcafe",
    winner_count: 2,
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 12_345,
    weather_station: "middle-wallop",
    weather_time: ~U[2026-04-09 13:00:00.000000Z],
    wallop_core_version: "0.17.0",
    fair_pick_version: "0.2.1"
  }

  @exec_input %{
    draw_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    operator_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    operator_slug: "acme-prizes",
    sequence: 42,
    lock_receipt_hash: "abcd" <> String.duplicate("0", 60),
    entry_hash: "e1",
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 12_345,
    drand_randomness: String.duplicate("a", 64),
    drand_signature: "deadbeef",
    weather_station: "middle-wallop",
    weather_observation_time: ~U[2026-04-09 13:15:00.000000Z],
    weather_value: "1013",
    weather_fallback_reason: nil,
    wallop_core_version: "0.17.0",
    fair_pick_version: "0.2.1",
    seed: "deadbeef" <> String.duplicate("0", 56),
    results: ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
    executed_at: ~U[2026-04-09 13:15:30.000000Z],
    signing_key_id: "cafebabe"
  }

  describe "cross-receipt field consistency (spec §4.2.5)" do
    test "lock + exec built from matching inputs agree on every cross-checked field" do
      lock = Protocol.build_receipt_payload(@lock_input) |> Jason.decode!()
      exec = Protocol.build_execution_receipt_payload(@exec_input) |> Jason.decode!()

      for field <- [
            "draw_id",
            "operator_id",
            "sequence",
            "drand_chain",
            "drand_round",
            "weather_station"
          ] do
        assert lock[field] == exec[field],
               "cross-checked field #{inspect(field)} differs: lock=#{inspect(lock[field])} exec=#{inspect(exec[field])}"
      end
    end

    test "weather observation time falls within the 1-hour window after weather_time" do
      lock = Protocol.build_receipt_payload(@lock_input) |> Jason.decode!()
      exec = Protocol.build_execution_receipt_payload(@exec_input) |> Jason.decode!()

      {:ok, lock_time, 0} = DateTime.from_iso8601(lock["weather_time"])
      {:ok, observation_time, 0} = DateTime.from_iso8601(exec["weather_observation_time"])

      delta = DateTime.diff(observation_time, lock_time, :second)

      assert delta >= 0, "observation_time precedes weather_time (delta=#{delta}s)"

      assert delta <= 3600,
             "observation_time is more than 1 hour after weather_time (delta=#{delta}s)"
    end

    test "signing_key_id is deliberately different across receipts" do
      # The lock receipt is signed by the operator's key; the exec receipt
      # by the wallop infrastructure key. These fields share the same
      # name but are different values by design. Any cross-field
      # consistency check MUST exclude signing_key_id.
      lock = Protocol.build_receipt_payload(@lock_input) |> Jason.decode!()
      exec = Protocol.build_execution_receipt_payload(@exec_input) |> Jason.decode!()

      refute lock["signing_key_id"] == exec["signing_key_id"],
             "test fixture accidentally uses the same signing_key_id on both receipts"
    end
  end
end
