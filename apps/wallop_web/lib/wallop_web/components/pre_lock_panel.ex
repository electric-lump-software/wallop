defmodule WallopWeb.Components.PreLockPanel do
  @moduledoc """
  Public proof-page panel for a draw in `:open` status.

  Takes a `WallopWeb.ProofPreLockView` struct and **only** that
  struct — does **not** accept the raw `Draw` resource. This is the
  structural firewall: a future PR adding a new field to `Draw`
  cannot be referenced from this component.

  The dedicated rate-limit bucket
  (`WallopWeb.Plugs.ProofPreLockRateLimit`) gates HTTP-level access;
  this component handles only what's allowlisted to render.

  See `spec/vectors/pre_lock_wide_gap_v1.json` and `spec/protocol.md`
  §4.3 (pre-lock proof-page rendering).
  """
  use WallopWeb, :html

  import WallopWeb.Components.PreLockTimeline
  import WallopWeb.Components.EntryCheck

  attr(:view, WallopWeb.ProofPreLockView, required: true)
  attr(:check_result, :map, default: nil)
  attr(:checked_entry_id, :string, default: nil)

  def pre_lock_panel(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-3">
        <span class="inline-flex items-center gap-1.5 bg-blue-100 text-blue-800 text-xs font-semibold px-3 py-1 rounded-full">
          Draw Open
        </span>
      </div>

      <div class="text-sm text-[#555] space-y-3">
        <div>
          <div>Draw ID: <span class="font-mono">{@view.id}</span></div>
          <.operator_link view={@view} />
        </div>
        <div>
          <div>Drawing {@view.winner_count} winner(s)</div>
          <div>{@view.entry_count} entries so far</div>
        </div>
      </div>

      <div class="bg-white border border-cream-border rounded-xl">
        <div class="p-5">
          <.pre_lock_timeline view={@view} />
        </div>
      </div>

      <div class="bg-white border border-cream-border rounded-xl">
        <div class="p-5">
          <.entry_check
            check_result={@check_result}
            draw_status={@view.status}
            checked_entry_id={@checked_entry_id}
            check_url={@view.check_url}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:view, WallopWeb.ProofPreLockView, required: true)

  defp operator_link(assigns) do
    ~H"""
    <div :if={@view.operator} class="text-sm">
      <a
        href={"/operator/#{@view.operator.slug}"}
        class="inline-flex flex-wrap items-baseline gap-x-1.5 text-[#555] hover:text-[#222]"
      >
        <span :if={@view.operator_sequence}>Draw #{@view.operator_sequence} by</span>
        <span :if={!@view.operator_sequence}>Draw by</span>
        <span class="font-semibold">{@view.operator.name}</span>
        <code class="text-xs text-[#888]">(@{@view.operator.slug})</code>
        <span aria-hidden="true">→</span>
      </a>
    </div>
    """
  end
end
