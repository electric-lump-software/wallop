defmodule WallopCore.Resources.Draw.Changes.IncrementApiKeyDrawCount do
  @moduledoc """
  After a successful draw create, increments the actor API key's
  monthly_draw_count via its `increment_draw_count` action.

  The actual tier limit check happens in `WallopWeb.Plugs.TierLimit`
  before the request reaches the Ash domain. This change just keeps the
  count up to date for the next check.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    actor = context.actor

    Ash.Changeset.after_action(changeset, fn _changeset, draw ->
      increment(actor)
      {:ok, draw}
    end)
  end

  defp increment(nil), do: :ok

  defp increment(api_key) do
    api_key
    |> Ash.Changeset.for_update(:increment_draw_count, %{})
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)

    :ok
  end
end
