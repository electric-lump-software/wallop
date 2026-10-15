defmodule WallopCore.Resources.Draw.BroadcastUpdateTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  defp mark_failed(draw, extra \\ & &1) do
    draw
    |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "test"})
    |> extra.()
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
  end

  test "a committed transition is broadcast" do
    draw = create_draw(create_api_key())
    Phoenix.PubSub.subscribe(WallopCore.PubSub, "draw:#{draw.id}")

    assert {:ok, _} = mark_failed(draw)
    assert_receive {:draw_updated, %{status: :failed}}
  end

  test "a transition that rolls back is not broadcast" do
    draw = create_draw(create_api_key())
    Phoenix.PubSub.subscribe(WallopCore.PubSub, "draw:#{draw.id}")

    assert {:error, _} =
             mark_failed(draw, &Ash.Changeset.after_action(&1, fn _, _ -> {:error, "boom"} end))

    refute_receive {:draw_updated, _}, 100
  end
end
