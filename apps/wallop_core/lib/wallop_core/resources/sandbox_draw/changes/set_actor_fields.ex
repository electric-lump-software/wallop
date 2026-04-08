defmodule WallopCore.Resources.SandboxDraw.Changes.SetActorFields do
  @moduledoc """
  Copies the acting `ApiKey`'s id (and operator_id, if any) onto the new
  sandbox draw row. Mirrors the real Draw create action's actor handling
  so the read policy (`api_key_id == actor`) works without the caller
  having to supply these fields.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{id: api_key_id} = api_key}) do
    changeset
    |> Ash.Changeset.force_change_attribute(:api_key_id, api_key_id)
    |> Ash.Changeset.force_change_attribute(:operator_id, Map.get(api_key, :operator_id))
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :api_key_id,
      message: "actor must be an ApiKey"
    )
  end
end
