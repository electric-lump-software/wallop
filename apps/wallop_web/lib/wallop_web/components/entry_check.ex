defmodule WallopWeb.Components.EntryCheck do
  @moduledoc """
  Entry self-check form. Allows a participant to verify whether
  their entry ID was in the draw and whether they won.
  """
  use WallopWeb, :html

  attr(:check_result, :map, default: nil)
  attr(:draw_status, :atom, default: :completed)
  attr(:checked_entry_id, :string, default: nil)

  def entry_check(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold mb-3">Check my entry</h3>
      <form phx-submit="check_entry" class="flex gap-2">
        <input
          type="text"
          name="entry_id"
          value={@checked_entry_id}
          placeholder="Enter your full entry ID"
          class="flex-1 px-3 py-1.5 rounded-lg border border-cream-border bg-white text-sm focus:outline-none focus:border-[#aaa]"
          required
        />
        <button type="submit" class="btn btn-neutral btn-sm rounded-lg">
          Check
        </button>
      </form>

      <div :if={@check_result} class="mt-3">
        <div :if={@check_result.found == false} class="bg-yellow-50 border border-yellow-200 text-yellow-800 rounded-lg px-4 py-3 text-sm">
          Entry not found in this draw.
        </div>
        <div :if={@check_result.found && @draw_status != :completed} class="bg-green-50 border border-green-200 text-green-800 rounded-lg px-4 py-3 text-sm">
          Your entry is in this draw.
        </div>
        <div :if={@check_result.found && @draw_status == :completed && @check_result.winner} class="bg-green-50 border border-green-200 text-green-800 rounded-lg px-4 py-3 text-sm">
          Your entry won! Position: {@check_result.position}
        </div>
        <div
          :if={@check_result.found && @draw_status == :completed && !@check_result.winner}
          class="bg-red-50 border border-red-200 text-red-800 rounded-lg px-4 py-3 text-sm"
        >
          Your entry was in this draw but did not win.
        </div>
      </div>
    </div>
    """
  end
end
