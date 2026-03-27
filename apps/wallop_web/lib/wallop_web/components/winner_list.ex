defmodule WallopWeb.Components.WinnerList do
  @moduledoc """
  Displays the anonymised list of winners with position badges.
  """
  use WallopWeb, :html

  alias WallopCore.Proof

  attr(:results, :list, required: true)

  def winner_list(assigns) do
    assigns = assign(assigns, :anonymised, Proof.anonymise_results(assigns.results))

    ~H"""
    <div>
      <h3 class="text-lg font-bold mb-3">Winners</h3>
      <div :if={@anonymised == []} class="text-sm text-[#555]">
        No winners recorded.
      </div>
      <ol :if={@anonymised != []} class="space-y-2">
        <li :for={result <- @anonymised} class="flex items-center gap-3">
          <span class="inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">
            {result["position"]}
          </span>
          <span class="font-mono text-sm">{result["entry_id"]}</span>
        </li>
      </ol>
    </div>
    """
  end
end
