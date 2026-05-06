defmodule WallopWeb.ProofPreLockViewTest do
  @moduledoc """
  Build-side allowlist regression for the public proof page on
  `:open` draws. Pins the struct shape so a future PR adding a new
  field to `Draw` cannot accidentally leak it via the proof page.

  Two assertions cover two surfaces:

  1. **Struct shape.** The `ProofPreLockView` struct has exactly the
     keys we intend to expose. New keys (or removed keys) require
     changing this allowlist deliberately, AND updating
     `spec/vectors/pre_lock_wide_gap_v1.json` AND the spec.

  2. **Wide-gap projection.** Given a `Draw` that has been *fully
     populated with every field that exists on the resource* — even
     fields that semantically can't exist pre-lock — the projection
     surfaces only the allowlisted subset. Forensic guard against
     "we forgot to project field X."
  """
  use ExUnit.Case, async: true

  alias WallopWeb.ProofPreLockView

  describe "struct shape (allowlist regression)" do
    test "exposes exactly the allowlisted keys, no more, no less" do
      expected_keys = [
        :id,
        :name,
        :status,
        :winner_count,
        :entry_count,
        :opened_at,
        :check_url,
        :operator_sequence,
        :operator
      ]

      actual_keys =
        %ProofPreLockView{}
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.sort()

      assert actual_keys == Enum.sort(expected_keys),
             """
             ProofPreLockView struct shape changed.

             Adding a field here is a deliberate widening of the public
             proof page surface for :open draws. Confirm:

             1. The new field is safe to expose pre-lock (won't leak entry
                weights, operator-internal IDs, or anything not yet
                publicly committed).
             2. The wide-gap test vector at
                spec/vectors/pre_lock_wide_gap_v1.json is updated.
             3. spec/protocol.md §4 documents the new exposure.
             """
    end
  end

  describe "from_draw/2" do
    test "projects only allowlisted fields from a fully-loaded draw" do
      # A "wide-gap" draw struct: every field populated as if it had
      # somehow reached :open with later-stage data attached. The
      # projection MUST drop everything not in the allowlist.
      draw = %{
        id: "11111111-2222-3333-4444-555555555555",
        name: "Public Name",
        status: :open,
        winner_count: 2,
        entry_count: 17,
        check_url: "https://operator.example/draw-info",
        inserted_at: ~U[2026-05-01 12:00:00.000000Z],
        stage_timestamps: %{"opened_at" => "2026-05-01T12:00:00.000000Z"},

        # Not on the allowlist — must NOT survive projection.
        api_key_id: "secret-key-id",
        operator_id: "secret-op-id",
        operator_sequence: 42,
        metadata: %{"internal" => "data"},
        callback_url: "https://operator.example/cb",

        # Cryptographic state that doesn't semantically exist pre-lock
        # but if it ever appeared on the struct, we still drop it.
        entry_hash: "fakehash",
        entry_canonical: "fakecanonical",
        seed: "fakeseed",
        seed_source: :entropy,
        results: [%{"position" => 1, "uuid" => "x"}],
        drand_round: 999,
        drand_chain: "leaked",
        drand_randomness: "leaked",
        drand_signature: "leaked",
        drand_response: "leaked",
        weather_station: "leaked",
        weather_time: ~U[2026-05-01 13:00:00Z],
        weather_value: "12.3",
        weather_raw: "leaked",
        weather_observation_time: ~U[2026-05-01 13:00:00Z],
        weather_fallback_reason: nil,
        executed_at: ~U[2026-05-01 13:00:00Z],
        failed_at: nil,
        failure_reason: nil
      }

      operator = %{slug: "op-slug", name: "Op Name", id: "secret-op-id", api_key_id: "k"}

      view = ProofPreLockView.from_draw(draw, operator)

      # Allowlisted fields present.
      assert view.id == "11111111-2222-3333-4444-555555555555"
      assert view.name == "Public Name"
      assert view.status == :open
      assert view.winner_count == 2
      assert view.entry_count == 17
      assert view.check_url == "https://operator.example/draw-info"
      assert %DateTime{} = view.opened_at
      assert view.operator == %{slug: "op-slug", name: "Op Name"}

      # The struct cannot carry fields outside its definition — this
      # is what makes the allowlist load-bearing. We assert that no
      # accidental keys leaked through by checking the rendered map
      # has exactly the expected keys.
      view_map = Map.from_struct(view)

      assert Map.keys(view_map) |> Enum.sort() ==
               [
                 :check_url,
                 :entry_count,
                 :id,
                 :name,
                 :opened_at,
                 :operator,
                 :operator_sequence,
                 :status,
                 :winner_count
               ]

      # Forensic check: no leaked field appears anywhere in the
      # rendered map's string representation.
      stringified = inspect(view_map)

      for forbidden <- [
            "secret-key-id",
            "secret-op-id",
            "fakehash",
            "fakecanonical",
            "fakeseed",
            "leaked"
          ] do
        refute String.contains?(stringified, forbidden),
               "pre-lock view leaked '#{forbidden}': #{stringified}"
      end
    end

    test "operator nil → operator key is nil" do
      draw = %{id: "11111111-2222-3333-4444-555555555555", status: :open, winner_count: 1}
      view = ProofPreLockView.from_draw(draw, nil)
      assert view.operator == nil
    end

    test "operator with extra fields → only slug and name carry through" do
      draw = %{id: "11111111-2222-3333-4444-555555555555", status: :open, winner_count: 1}

      operator = %{
        slug: "s",
        name: "n",
        id: "should-not-appear",
        public_key: "should-not-appear",
        tier: :tier_1
      }

      view = ProofPreLockView.from_draw(draw, operator)
      assert view.operator == %{slug: "s", name: "n"}
    end

    test "entry_count nil defaults to 0" do
      draw = %{
        id: "11111111-2222-3333-4444-555555555555",
        status: :open,
        winner_count: 1,
        entry_count: nil
      }

      view = ProofPreLockView.from_draw(draw, nil)
      assert view.entry_count == 0
    end

    test "raises on non-:open status (defensive guard against future code paths)" do
      for bad <- [:locked, :awaiting_entropy, :pending_entropy, :completed, :failed, :expired] do
        assert_raise ArgumentError, ~r/non-open draw/, fn ->
          ProofPreLockView.from_draw(%{status: bad}, nil)
        end
      end
    end

    test "opened_at falls back to inserted_at when stage_timestamps absent" do
      draw = %{
        id: "11111111-2222-3333-4444-555555555555",
        status: :open,
        winner_count: 1,
        inserted_at: ~U[2026-05-01 12:00:00.000000Z]
      }

      view = ProofPreLockView.from_draw(draw, nil)
      assert view.opened_at == ~U[2026-05-01 12:00:00.000000Z]
    end

    test "opened_at parses ISO8601 from stage_timestamps when present" do
      draw = %{
        id: "11111111-2222-3333-4444-555555555555",
        status: :open,
        winner_count: 1,
        stage_timestamps: %{"opened_at" => "2026-05-01T12:00:00.000000Z"}
      }

      view = ProofPreLockView.from_draw(draw, nil)
      assert %DateTime{} = view.opened_at
    end
  end
end
