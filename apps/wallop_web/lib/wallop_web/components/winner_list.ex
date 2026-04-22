defmodule WallopWeb.Components.WinnerList do
  @moduledoc """
  Displays the list of winning UUIDs with position badges.

  For draws with more than 100 winners, switches to a virtualised list
  rendered inside a fixed-height scroll container. Rows are mounted and
  unmounted as the user scrolls (windowing) to keep DOM size constant.
  """
  use WallopWeb, :html

  @virtualise_threshold 100

  attr(:results, :list, required: true)

  def winner_list(assigns) do
    results = assigns.results || []

    assigns =
      assigns
      |> assign(:results, results)
      |> assign(:count, length(results))
      |> assign(:virtualise?, length(results) > @virtualise_threshold)
      |> assign(:winners_json, Jason.encode!(results))

    ~H"""
    <div>
      <h3 class="text-lg font-bold mb-3">Winners</h3>
      <div :if={@results == []} class="text-sm text-[#555]">
        No winners recorded.
      </div>

      <ol :if={@results != [] and not @virtualise?} class="space-y-2">
        <li :for={result <- @results} class="flex items-center gap-3">
          <span class="inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">
            {result["position"]}
          </span>
          <span class="font-mono text-sm">{result["entry_id"]}</span>
        </li>
      </ol>

      <div :if={@virtualise?}>
        <p class="text-xs text-[#777] mb-2">{@count} winners</p>
        <div
          data-virtual-winners
          data-winners-json={@winners_json}
          class="relative h-[420px] overflow-y-auto border border-cream-border rounded-lg bg-white"
        >
          <div data-virtual-spacer class="relative w-full"></div>
        </div>
      </div>
    </div>
    """
  end
end
