defmodule WallopWeb.Components.EntryCheck do
  @moduledoc """
  Entry self-check form. Allows a participant to verify whether
  their entry ID was in the draw and whether they won.
  """
  use WallopWeb, :html

  attr(:check_result, :map, default: nil)

  def entry_check(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold mb-3">Check my entry</h3>
      <form phx-submit="check_entry" class="flex gap-2">
        <input
          type="text"
          name="entry_id"
          placeholder="Enter your full entry ID"
          class="input input-bordered input-sm flex-1"
          required
        />
        <button type="submit" class="btn btn-primary btn-sm">
          Check
        </button>
      </form>

      <div :if={@check_result} class="mt-3">
        <div :if={@check_result.found == false} class="alert alert-warning text-sm">
          Entry not found in this draw.
        </div>
        <div :if={@check_result.found && @check_result.winner} class="alert alert-success text-sm">
          Your entry won! Position: {@check_result.position}
        </div>
        <div
          :if={@check_result.found && !@check_result.winner}
          class="alert alert-info text-sm"
        >
          Your entry was in this draw but did not win.
        </div>
      </div>
    </div>
    """
  end
end
