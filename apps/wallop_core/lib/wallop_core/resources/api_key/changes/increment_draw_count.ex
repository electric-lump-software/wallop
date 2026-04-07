defmodule WallopCore.Resources.ApiKey.Changes.IncrementDrawCount do
  @moduledoc """
  Increments `monthly_draw_count` by 1.

  If `count_reset_at` is in the past, resets the count to 1 and advances
  `count_reset_at` to one calendar month from now.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    api_key = changeset.data
    now = DateTime.utc_now()

    {new_count, new_reset_at} =
      cond do
        api_key.count_reset_at == nil ->
          {1, advance_one_month(now)}

        DateTime.compare(now, api_key.count_reset_at) != :lt ->
          {1, advance_one_month(now)}

        true ->
          {(api_key.monthly_draw_count || 0) + 1, api_key.count_reset_at}
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:monthly_draw_count, new_count)
    |> Ash.Changeset.force_change_attribute(:count_reset_at, new_reset_at)
  end

  defp advance_one_month(dt) do
    dt
    |> DateTime.add(30 * 86_400, :second)
    |> DateTime.truncate(:second)
  end
end
