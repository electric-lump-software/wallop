defmodule WallopWeb.Components.EntryCheck do
  @moduledoc """
  Entry self-check form. Flat-boolean lookup against the published
  winner list.

  This endpoint intentionally returns the same response for every
  non-winning input — whether the UUID entered but didn't win, never
  entered at all, or was malformed. Preventing the three cases from
  being distinguishable is what stops the endpoint from becoming an
  enumeration oracle keyed by UUID. Operators who want to offer a
  richer "check your ticket" experience (entered yes/no, position,
  etc.) should build their own authenticated page and link it from
  the draw's `metadata.check_url`.
  """
  use WallopWeb, :html

  attr(:check_result, :map, default: nil)
  attr(:draw_status, :atom, default: :completed)
  attr(:checked_entry_id, :string, default: nil)

  attr(:check_url, :string,
    default: nil,
    doc: "Optional operator-supplied link to their own ticket-check page."
  )

  def entry_check(assigns) do
    ~H"""
    <div>
      <h3 class="text-lg font-bold mb-3">Check a winning UUID</h3>

      <p class="text-xs text-[#777] mb-3">
        Paste a wallop-assigned UUID to check whether it is in the published
        winner list. For any other status — "did my entry get submitted",
        "am I entered", "what position did I come" — check with the operator
        running this draw; they hold the private mapping from UUID to ticket.
      </p>

      <form phx-submit="check_entry" class="flex gap-2">
        <input
          type="text"
          name="entry_id"
          value={@checked_entry_id}
          placeholder="Paste a UUID (e.g. aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa)"
          class="flex-1 px-3 py-1.5 rounded-lg border border-cream-border bg-white text-sm font-mono focus:outline-none focus:border-[#aaa]"
          required
        />
        <button type="submit" class="btn btn-neutral btn-sm rounded-lg">
          Check
        </button>
      </form>

      <div :if={@check_result} class="mt-3">
        <div :if={@draw_status != :completed} class="bg-cream-50 border border-cream-border text-[#555] rounded-lg px-4 py-3 text-sm">
          The draw hasn't completed yet — no winners to check against.
        </div>
        <div :if={@draw_status == :completed && @check_result.winner} class="bg-green-50 border border-green-200 text-green-800 rounded-lg px-4 py-3 text-sm">
          This UUID is in the winner list.
        </div>
        <div
          :if={@draw_status == :completed && !@check_result.winner}
          class="bg-yellow-50 border border-yellow-200 text-yellow-800 rounded-lg px-4 py-3 text-sm"
        >
          <p>
            Not in the winner list. To check whether your entry was submitted,
            contact the operator of this draw.
          </p>
          <p :if={@check_url} class="mt-2">
            The operator provides a ticket-check page at:
            <a
              href={@check_url}
              target="_blank"
              rel="noopener noreferrer"
              class="underline break-all"
            >{@check_url}</a>
          </p>
        </div>
      </div>
    </div>
    """
  end
end
