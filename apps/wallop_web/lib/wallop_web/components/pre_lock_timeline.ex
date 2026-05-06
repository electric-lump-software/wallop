defmodule WallopWeb.Components.PreLockTimeline do
  @moduledoc """
  Vertical timeline for the public proof page on a draw in `:open`
  status (pre-lock).

  Renders the same six-stage daisyUI steps shape as
  `WallopWeb.Components.DrawTimeline`, but binds **only** to fields
  on `WallopWeb.ProofPreLockView` — never to the full `Draw`
  resource. The first stage ("Entries Open") is `:current`; the
  remaining five are placeholder `:pending` (no detail, no
  timestamp) because none of those fields exist yet pre-lock.

  This is the structural firewall PR #193 intended: the component
  cannot accidentally leak a future `Draw` field via the proof page
  on `:open` draws because it has no path to read one.

  Post-lock proof pages continue to use the full
  `WallopWeb.Components.DrawTimeline` against the live `Draw`
  resource — that component is strictly typed for the post-lock
  shape and was never the right shape for `:open`.
  """
  use WallopWeb, :html

  attr(:view, WallopWeb.ProofPreLockView, required: true)

  def pre_lock_timeline(assigns) do
    assigns = assign(assigns, :stages, build_stages(assigns.view))

    ~H"""
    <ul class="steps steps-vertical w-full">
      <li
        :for={{stage, idx} <- Enum.with_index(@stages)}
        class={step_class(stage.state)}
        data-content={idx}
        data-reveal-step={idx}
      >
        <div class="text-left py-2">
          <div class="font-semibold text-sm">{stage.label}</div>
          <div :if={stage.detail} class="text-xs text-[#555] mt-0.5">
            {stage.detail}
          </div>
        </div>
      </li>
    </ul>
    """
  end

  # Six stages, matching the post-lock timeline's shape so the
  # progress indicator is consistent across statuses. Only the
  # "Entries Open" stage carries detail (entry count); the rest are
  # pure placeholders because the underlying fields don't yet exist.
  defp build_stages(%WallopWeb.ProofPreLockView{entry_count: count}) do
    [
      %{label: "Entries Open", detail: "#{count} entries", state: :current},
      %{label: "Entries Locked", detail: nil, state: :pending},
      %{label: "Entropy Declared", detail: nil, state: :pending},
      %{label: "Fetching Entropy", detail: nil, state: :pending},
      %{label: "Computing Seed", detail: nil, state: :pending},
      %{label: "Winners Selected", detail: nil, state: :pending}
    ]
  end

  defp step_class(:current), do: "step step-done step-current"
  defp step_class(:pending), do: "step"
end
