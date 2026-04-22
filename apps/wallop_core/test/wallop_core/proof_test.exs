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

  describe "check_entry/2 (legacy)" do
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

    test "returns found + winner for a winning uuid", %{draw: draw, winner_uuids: winner_uuids} do
      winning = List.first(winner_uuids)

      assert {:ok, %{found: true, winner: true, position: pos}} =
               Proof.check_entry(draw, winning)

      assert is_integer(pos)
    end

    test "returns found + not winner for a non-winning uuid", %{
      draw: draw,
      winner_uuids: winner_uuids
    } do
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      loser = Enum.find(all_uuids, fn u -> u not in winner_uuids end)

      assert {:ok, %{found: true, winner: false}} = Proof.check_entry(draw, loser)
    end

    test "returns not found for unknown uuid", %{draw: draw} do
      assert {:ok, %{found: false}} =
               Proof.check_entry(draw, "00000000-0000-4000-8000-000000000000")
    end
  end
end
