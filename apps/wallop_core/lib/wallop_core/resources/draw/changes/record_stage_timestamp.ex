defmodule WallopCore.Resources.Draw.Changes.RecordStageTimestamp do
  @moduledoc """
  Appends a timestamp to the stage_timestamps map.

  Usage: `change {RecordStageTimestamp, key: "opened_at"}`

  Merges the new key into the existing map. Never overwrites existing keys.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    key = Keyword.fetch!(opts, :key)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    existing =
      Ash.Changeset.get_attribute(changeset, :stage_timestamps) || %{}

    if Map.has_key?(existing, key) do
      changeset
    else
      Ash.Changeset.force_change_attribute(
        changeset,
        :stage_timestamps,
        Map.put(existing, key, now)
      )
    end
  end
end
