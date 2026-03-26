defmodule WallopCore.Resources.Draw.Changes.ValidateCallbackUrl do
  @moduledoc "Validates callback_url if provided."
  use Ash.Resource.Change

  alias WallopCore.Entropy.CallbackUrl

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :callback_url) do
      nil ->
        changeset

      url ->
        case CallbackUrl.validate(url) do
          :ok ->
            changeset

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, field: :callback_url, message: reason)
        end
    end
  end
end
