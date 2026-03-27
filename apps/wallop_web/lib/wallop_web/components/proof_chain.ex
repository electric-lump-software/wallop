defmodule WallopWeb.Components.ProofChain do
  @moduledoc """
  Proof chain component showing the four verification steps
  for a completed draw.
  """
  use WallopWeb, :html

  @drand_base_url "https://api.drand.sh"

  attr(:draw, :map, required: true)

  def proof_chain(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="text-lg font-bold">How to verify</h3>

      <%!-- Step 1: Entry Hash --%>
      <div class="bg-cream-dark border border-cream-border rounded-xl">
        <div class="p-4">
          <div class="flex items-start gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">1</span>
            <div>
              <div class="font-semibold text-sm">Entry Hash</div>
              <div class="text-xs text-[#555] mt-1">
                SHA-256 of the canonical entry list, computed before the draw.
              </div>
              <code class="text-xs font-mono mt-1 block break-all">
                {@draw.entry_hash}
              </code>
            </div>
          </div>
        </div>
      </div>

      <%!-- Step 2: Entropy Sources --%>
      <div class="bg-cream-dark border border-cream-border rounded-xl">
        <div class="p-4">
          <div class="flex items-start gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">2</span>
            <div>
              <div class="font-semibold text-sm">Entropy Sources</div>
              <div :if={@draw.drand_round} class="mt-2">
                <span class="text-xs text-[#555]">drand round: </span>
                <a
                  href={drand_url(@draw.drand_chain, @draw.drand_round)}
                  target="_blank"
                  rel="noopener"
                  class="text-[#555] underline hover:text-[#1a1a1a] text-xs"
                >
                  #{@draw.drand_round}
                </a>
                <div :if={@draw.drand_randomness} class="text-xs font-mono mt-1 break-all">
                  {@draw.drand_randomness}
                </div>
              </div>
              <div :if={@draw.weather_value} class="mt-2">
                <span class="text-xs text-[#555]">Weather value: </span>
                <span class="text-xs font-mono">{@draw.weather_value}</span>
                <span :if={@draw.weather_station} class="text-xs text-[#555]">
                  (station: {@draw.weather_station})
                </span>
                <div :if={@draw.weather_observation_time} class="text-xs text-[#555] mt-0.5">
                  Observation from {Calendar.strftime(@draw.weather_observation_time, "%H:%M UTC %d %b %Y")}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Step 3: Seed Computation --%>
      <div class="bg-cream-dark border border-cream-border rounded-xl">
        <div class="p-4">
          <div class="flex items-start gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">3</span>
            <div>
              <div class="font-semibold text-sm">Seed Computation</div>
              <div class="text-xs text-[#555] mt-1">
                seed = SHA-256(JCS(entry_hash, drand_randomness, weather_value))
              </div>
              <code class="text-xs font-mono mt-1 block break-all">
                {@draw.seed}
              </code>
            </div>
          </div>
        </div>
      </div>

      <%!-- Step 4: Algorithm --%>
      <div class="bg-cream-dark border border-cream-border rounded-xl">
        <div class="p-4">
          <div class="flex items-start gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">4</span>
            <div>
              <div class="font-semibold text-sm">Algorithm</div>
              <div class="text-xs text-[#555] mt-1">
                Deterministic Fisher-Yates shuffle via
                <a
                  href="https://github.com/electric-lump-software/fair_pick"
                  target="_blank"
                  rel="noopener"
                  class="text-[#555] underline hover:text-[#1a1a1a]"
                >
                  fair_pick
                </a>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp drand_url(chain, round) do
    chain = chain || "dbd506d6ef76e5f386f41c651dcb808c5bcbd75471cc4eafa3f4df7ad4e4c493"
    "#{@drand_base_url}/#{chain}/public/#{round}"
  end
end
