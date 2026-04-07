defmodule WallopCore.Resources.ApiKey.Changes.AdvanceResetAt do
  @moduledoc "Sets count_reset_at to one month from now."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    next =
      DateTime.utc_now()
      |> DateTime.add(30 * 86_400, :second)
      |> DateTime.truncate(:second)

    Ash.Changeset.force_change_attribute(changeset, :count_reset_at, next)
  end
end
