defmodule WallopCore.Entropy.ExpiryWorkerTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.ExpiryWorker

  defp create_open_draw do
    api_key = create_api_key()

    draw =
      WallopCore.Resources.Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
      |> Ash.create!()

    {api_key, draw}
  end

  defp backdate_draw(draw, days_ago) do
    old_time = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

    WallopCore.Repo.query!("UPDATE draws SET inserted_at = $1 WHERE id = $2", [
      old_time,
      Ecto.UUID.dump!(draw.id)
    ])
  end

  defp reload_draw(draw) do
    Ash.get!(WallopCore.Resources.Draw, draw.id, authorize?: false)
  end

  describe "perform/1" do
    test "expires old open draws" do
      {_api_key, draw} = create_open_draw()
      assert draw.status == :open

      backdate_draw(draw, 91)

      assert :ok = ExpiryWorker.perform(%{})

      reloaded = reload_draw(draw)
      assert reloaded.status == :expired
    end

    test "does not expire recent open draws" do
      {_api_key, draw} = create_open_draw()
      assert draw.status == :open

      assert :ok = ExpiryWorker.perform(%{})

      reloaded = reload_draw(draw)
      assert reloaded.status == :open
    end

    test "does not expire awaiting_entropy draws" do
      api_key = create_api_key()
      draw = create_draw(api_key)
      assert draw.status == :awaiting_entropy

      backdate_draw(draw, 91)

      assert :ok = ExpiryWorker.perform(%{})

      reloaded = reload_draw(draw)
      assert reloaded.status == :awaiting_entropy
    end

    test "returns :ok with no eligible draws" do
      assert :ok = ExpiryWorker.perform(%{})
    end
  end
end
