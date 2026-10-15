defmodule WallopCore.Resources.Draw.Changes.EnqueueWebhook do
  @moduledoc """
  Enqueues the draw's webhook in the same transaction as its terminal
  transition, so the outcome and its notification commit or roll back
  together. A crash between the two can no longer leave a completed draw
  whose webhook was never queued.
  """
  use Ash.Resource.Change

  alias WallopCore.Entropy.WebhookWorker

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draw -> enqueue(draw) end)
  end

  defp enqueue(%{callback_url: url, api_key_id: api_key_id} = draw)
       when is_binary(url) and is_binary(api_key_id) do
    case %{draw_id: draw.id, api_key_id: api_key_id} |> WebhookWorker.new() |> Oban.insert() do
      {:ok, _job} -> {:ok, draw}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue(draw), do: {:ok, draw}
end
