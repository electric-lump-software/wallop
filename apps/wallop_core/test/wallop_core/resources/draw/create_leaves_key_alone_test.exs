defmodule WallopCore.Resources.Draw.CreateLeavesKeyAloneTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  alias WallopCore.Resources.{ApiKey, Draw}

  # Writes the deprecated quota columns directly, as a consumer on an older
  # wallop_core still can. Nothing in this version may act on them.
  defp exhaust_old_quota(key) do
    WallopCore.Repo.query!(
      "UPDATE api_keys SET tier = 'frozen', monthly_draw_limit = 0, monthly_draw_count = 5, " <>
        "count_reset_at = now() + interval '7 days' WHERE id = $1",
      [Ecto.UUID.dump!(key.id)]
    )

    Ash.get!(ApiKey, key.id, authorize?: false)
  end

  defp create(key),
    do: Draw |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: key) |> Ash.create()

  test "creating a draw doesn't write to the API key" do
    key = create_api_key()
    before = Ash.get!(ApiKey, key.id, authorize?: false)

    assert {:ok, _} = create(key)

    now = Ash.get!(ApiKey, key.id, authorize?: false)
    assert now.updated_at == before.updated_at
    assert now.monthly_draw_count == before.monthly_draw_count
  end

  test "the old quota columns don't stop a draw being created" do
    key = create_api_key() |> exhaust_old_quota()
    assert {:ok, _} = create(key)
  end

  test "an open draw can still take entries and lock after its key's old quota columns change" do
    key = create_api_key()
    {:ok, draw} = create(key)
    key = exhaust_old_quota(key)

    assert {:ok, draw} =
             draw
             |> Ash.Changeset.for_update(
               :add_entries,
               %{entries: [%{weight: 1}, %{weight: 1}], client_ref: Ash.UUID.generate()},
               actor: key
             )
             |> Ash.update()

    assert {:ok, %{status: :awaiting_entropy}} =
             draw |> Ash.Changeset.for_update(:lock, %{}, actor: key) |> Ash.update()
  end
end
