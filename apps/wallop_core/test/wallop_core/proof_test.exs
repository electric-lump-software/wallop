defmodule WallopCore.ProofTest do
  use WallopCore.DataCase, async: true
  import WallopCore.TestHelpers

  alias WallopCore.Proof

  describe "anonymise_id/1" do
    test "shows first character + fixed mask" do
      assert Proof.anonymise_id("ticket-47") == "t******"
    end

    test "single character gets mask" do
      assert Proof.anonymise_id("a") == "a******"
    end

    test "two characters gets mask" do
      assert Proof.anonymise_id("ab") == "a******"
    end

    test "three characters gets mask" do
      assert Proof.anonymise_id("abc") == "a******"
    end

    test "long ID gets same mask length" do
      assert Proof.anonymise_id("entry-1234-abcdef") == "e******"
    end
  end

  describe "anonymise_results/1" do
    test "anonymises all entry_ids in results" do
      results = [
        %{"position" => 1, "entry_id" => "charlie"},
        %{"position" => 2, "entry_id" => "alice"}
      ]

      anonymised = Proof.anonymise_results(results)

      assert Enum.at(anonymised, 0)["entry_id"] == "c******"
      assert Enum.at(anonymised, 1)["entry_id"] == "a******"
      # Positions preserved
      assert Enum.at(anonymised, 0)["position"] == 1
    end
  end

  describe "verify/1" do
    test "returns :verified for a correctly executed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      assert {:ok, :verified} = Proof.verify(draw)
    end
  end

  describe "check_entry/2" do
    setup do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          entries: [
            %{"id" => "winner-1", "weight" => 1},
            %{"id" => "winner-2", "weight" => 1},
            %{"id" => "loser-1", "weight" => 1}
          ],
          winner_count: 2
        })

      draw = execute_draw(draw, test_seed(), api_key)

      # Find which entries actually won
      winner_ids = Enum.map(draw.results, & &1["entry_id"])

      %{draw: draw, winner_ids: winner_ids}
    end

    test "returns found + winner for a winning entry", %{draw: draw, winner_ids: winner_ids} do
      winning_id = List.first(winner_ids)

      assert {:ok, %{found: true, winner: true, position: pos}} =
               Proof.check_entry(draw, winning_id)

      assert is_integer(pos)
    end

    test "returns found + not winner for a non-winning entry", %{
      draw: draw,
      winner_ids: winner_ids
    } do
      all_ids = Enum.map(draw.entries, & &1["id"])
      loser_id = Enum.find(all_ids, fn id -> id not in winner_ids end)

      assert {:ok, %{found: true, winner: false}} = Proof.check_entry(draw, loser_id)
    end

    test "returns not found for unknown entry", %{draw: draw} do
      assert {:ok, %{found: false}} = Proof.check_entry(draw, "nonexistent-entry")
    end
  end
end
