defmodule WallopWeb.Components.ProofChain do
  @moduledoc """
  Proof chain component showing the four verification steps
  for a completed draw.
  """
  use WallopWeb, :html

  @drand_base_url "https://api.drand.sh"

  attr(:draw, :map, required: true)

  attr(:weather, :map,
    default: nil,
    doc: "`WallopWeb.ProofWeather.summary/3` for lock schema 6 draws; nil otherwise"
  )

  def proof_chain(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="text-lg font-bold">How to verify</h3>

      <%!-- Step 1: Entry Hash --%>
      <div class="bg-cream-dark border border-cream-border rounded-xl">
        <div class="p-4">
          <div class="flex items-start gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 min-w-6 min-h-6 shrink-0 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">1</span>
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
            <span class="inline-flex items-center justify-center w-6 h-6 min-w-6 min-h-6 shrink-0 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">2</span>
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
              <.observation_weather :if={@weather} weather={@weather} />
            </div>
          </div>
        </div>
      </div>

      <%!-- Step 3: Seed Computation --%>
      <div class="bg-cream-dark border border-cream-border rounded-xl">
        <div class="p-4">
          <div class="flex items-start gap-3">
            <span class="inline-flex items-center justify-center w-6 h-6 min-w-6 min-h-6 shrink-0 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">3</span>
            <div>
              <div class="font-semibold text-sm">Seed Computation</div>
              <div :if={@weather} class="text-xs text-[#555] mt-1">
                {seed_formula(@weather.source)}
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
            <span class="inline-flex items-center justify-center w-6 h-6 min-w-6 min-h-6 shrink-0 bg-[#1a1a1a] text-white text-xs font-mono rounded-full">4</span>
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

      <div class="text-xs text-[#555]">
        Verify manually with
        <a href="https://github.com/electric-lump-software/fair_pick" target="_blank" rel="noopener" class="underline hover:text-[#1a1a1a]">fair_pick</a>
        (Elixir) or
        <a href="https://github.com/electric-lump-software/fair_pick_rs" target="_blank" rel="noopener" class="underline hover:text-[#1a1a1a]">fair_pick_rs</a>
        (Rust)
      </div>
    </div>
    """
  end

  attr(:weather, :map, required: true)

  # What the signed receipts say the draw used. Display only, and headed
  # as such: the browser check's verifier gate is what shows a match.
  defp observation_weather(assigns) do
    ~H"""
    <div class="mt-2 text-xs text-[#555] space-y-1" data-observation-weather={@weather.source || "none"}>
      <div :if={@weather.observation_hour}>
        Weather hour: {Calendar.strftime(@weather.observation_hour, "%H:%M UTC %d %b %Y")}.
        Set by the draw's drand round, so nobody gets to pick it; the check above confirms it.
      </div>

      <div :if={@weather.source} class="pt-1 space-y-1" data-signed-receipt-says>
        <div class="font-semibold text-[#1a1a1a]">The signed receipt says:</div>

        <div :if={@weather.source == :weather}>
          <div>
            {@weather.station_label} reported this at {Calendar.strftime(@weather.observed_at, "%H:%M UTC %d %b %Y")}:
          </div>
          <div>
            Weather value: <span class="font-mono">{@weather.weather_value}</span>
          </div>
        </div>

        <div :if={@weather.fallback_label} class="text-[#1a1a1a]">
          {@weather.fallback_label}
        </div>

        <div :if={@weather.source == :frequency} class="space-y-1">
          <div>
            Grid frequency readings (mHz): <span class="font-mono break-all">{@weather.freq_value}</span>
          </div>
          <div :if={@weather.freq_start}>
            Eight readings, 15 seconds apart, from T =
            {Calendar.strftime(@weather.freq_start, "%H:%M:%S UTC %d %b %Y")}
          </div>
          <div class="text-[#777]">{@weather.bmrs_line}</div>
        </div>

        <div :if={@weather.check_line}>{@weather.check_line}</div>

        <div class="pt-1">
          What you're trusting here:
          <ul class="list-disc ml-4">
            <li :for={line <- @weather.trust_lines}>{line}</li>
          </ul>
        </div>
      </div>

      <div :if={@weather.out_of_table} class="text-red-700">
        {@weather.out_of_table_text}
      </div>
    </div>
    """
  end

  defp seed_formula(:weather),
    do: "seed = SHA-256(JCS(entry_hash, drand_randomness, weather_value))"

  defp seed_formula(:frequency),
    do: "seed = SHA-256(JCS(entry_hash, drand_randomness, freq_value))"

  defp seed_formula(:drand_only), do: "seed = SHA-256(JCS(entry_hash, drand_randomness))"
  defp seed_formula(nil), do: nil

  defp drand_url(chain, round) do
    chain = chain || "dbd506d6ef76e5f386f41c651dcb808c5bcbd75471cc4eafa3f4df7ad4e4c493"
    "#{@drand_base_url}/#{chain}/public/#{round}"
  end
end
