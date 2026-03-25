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
      <div :if={@anonymised == []} class="text-sm text-base-content/60">
        No winners recorded.
      </div>
      <ol :if={@anonymised != []} class="space-y-2">
        <li :for={result <- @anonymised} class="flex items-center gap-3">
          <span class="badge badge-primary badge-sm font-mono">
            {result["position"]}
          </span>
          <span class="font-mono text-sm">{result["entry_id"]}</span>
        </li>
      </ol>
    </div>
    """
  end
end
