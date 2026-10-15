defmodule WallopCore.Resources.Draw.EnqueueWebhookTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.WebhookWorker

  defp locked_with_callback(key) do
    create_draw(key, %{callback_url: "https://example.com/hook"})
  end

  defp fail(draw) do
    draw
    |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "test"})
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
  end

  test "completing a draw enqueues its webhook" do
    key = create_api_key()
    draw = locked_with_callback(key)
    execute_draw(draw, nil, key)
    assert_enqueued(worker: WebhookWorker, args: %{draw_id: draw.id, api_key_id: key.id})
  end

  test "failing a draw enqueues its webhook" do
    key = create_api_key()
    draw = locked_with_callback(key)
    assert {:ok, _} = fail(draw)
    assert_enqueued(worker: WebhookWorker, args: %{draw_id: draw.id})
  end

  test "no callback_url, no webhook" do
    key = create_api_key()
    draw = create_draw(key)
    assert {:ok, _} = fail(draw)
    refute_enqueued(worker: WebhookWorker)
  end

  test "the job rolls back with the transition" do
    key = create_api_key()
    draw = locked_with_callback(key)

    WallopCore.Repo.transaction(fn ->
      {:ok, _} = fail(draw)
      WallopCore.Repo.rollback(:test)
    end)

    refute_enqueued(worker: WebhookWorker)

    assert Ash.get!(WallopCore.Resources.Draw, draw.id, authorize?: false).status ==
             :awaiting_entropy
  end
end
