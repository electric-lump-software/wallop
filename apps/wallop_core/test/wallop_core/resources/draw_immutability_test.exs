defmodule WallopCore.Resources.DrawImmutabilityTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL

  describe "completed draw immutability (DB trigger)" do
    setup do
      api_key = create_api_key()
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)
      %{draw: executed}
    end

    test "cannot UPDATE a completed draw via raw SQL", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify a completed draw/, fn ->
        SQL.query!(
          WallopCore.Repo,
          "UPDATE draws SET winner_count = 999 WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot DELETE a completed draw via raw SQL", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot delete a completed draw/, fn ->
        SQL.query!(
          WallopCore.Repo,
          "DELETE FROM draws WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "locked draw protection (DB trigger)" do
    setup do
      api_key = create_api_key()
      draw = create_draw(api_key)
      %{draw: draw}
    end

    test "cannot modify committed fields on a locked draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify committed entry fields/, fn ->
        SQL.query!(
          WallopCore.Repo,
          "UPDATE draws SET winner_count = 999 WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "can DELETE a locked draw (cancellation)", %{draw: draw} do
      result =
        SQL.query!(
          WallopCore.Repo,
          "DELETE FROM draws WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )

      assert result.num_rows == 1
    end
  end
end
