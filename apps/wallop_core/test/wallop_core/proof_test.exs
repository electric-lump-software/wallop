defmodule WallopCore.ProofTest do
  use WallopCore.DataCase, async: true
  import WallopCore.TestHelpers

  alias WallopCore.Proof

  describe "verify/1" do
    test "returns :verified for a correctly executed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      assert {:ok, :verified} = Proof.verify(draw)
    end
  end

  describe "winner?/2" do
    setup do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          entries: [
            %{"ref" => "winner-1", "weight" => 1},
            %{"ref" => "winner-2", "weight" => 1},
            %{"ref" => "loser-1", "weight" => 1}
          ],
          winner_count: 2
        })

      draw = execute_draw(draw, test_seed(), api_key)

      winner_uuids = Enum.map(draw.results, & &1["entry_id"])
      %{draw: draw, winner_uuids: winner_uuids}
    end

    test "returns true for a winning uuid", %{draw: draw, winner_uuids: winner_uuids} do
      winner = List.first(winner_uuids)
      assert {:ok, %{winner: true}} = Proof.winner?(draw, winner)
    end

    test "returns false for a valid uuid that entered but didn't win", %{
      draw: draw,
      winner_uuids: winner_uuids
    } do
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      loser = Enum.find(all_uuids, fn u -> u not in winner_uuids end)

      assert {:ok, %{winner: false}} = Proof.winner?(draw, loser)
    end

    test "returns false for a uuid that never entered the draw", %{draw: draw} do
      never_entered = "00000000-0000-4000-8000-000000000000"
      assert {:ok, %{winner: false}} = Proof.winner?(draw, never_entered)
    end

    test "returns false for malformed input", %{draw: draw} do
      assert {:ok, %{winner: false}} = Proof.winner?(draw, "not-a-uuid")
      assert {:ok, %{winner: false}} = Proof.winner?(draw, "")
    end
  end

  describe "winner?/2 — byte-identical responses for non-winner cases" do
    # The self-check endpoint collapses three distinct non-winner cases
    # into one response shape: "UUID entered but didn't win", "UUID never
    # entered", and "malformed input" all produce identical bytes. This
    # prevents the endpoint from becoming an enumeration oracle keyed by
    # UUID. Pre-launch decision (confirmed with Colin).

    setup do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          entries: [
            %{"ref" => "winner-1", "weight" => 1},
            %{"ref" => "winner-2", "weight" => 1},
            %{"ref" => "loser-1", "weight" => 1}
          ],
          winner_count: 2
        })

      draw = execute_draw(draw, test_seed(), api_key)
      winner_uuids = Enum.map(draw.results, & &1["entry_id"])
      %{draw: draw, winner_uuids: winner_uuids}
    end

    test "valid non-winning UUID, never-entered UUID, and malformed input produce identical bytes",
         %{draw: draw, winner_uuids: winner_uuids} do
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      loser = Enum.find(all_uuids, fn u -> u not in winner_uuids end)

      never_entered = "00000000-0000-4000-8000-000000000000"
      malformed = "df"
      garbage = "not-a-uuid-at-all"

      responses = [
        Proof.winner?(draw, loser),
        Proof.winner?(draw, never_entered),
        Proof.winner?(draw, malformed),
        Proof.winner?(draw, garbage),
        Proof.winner?(draw, "")
      ]

      assert Enum.all?(responses, &(&1 == {:ok, %{winner: false}}))
      assert Enum.uniq(responses) == [{:ok, %{winner: false}}]
    end
  end
end
