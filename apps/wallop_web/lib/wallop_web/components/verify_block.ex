defmodule WallopWeb.Components.VerifyBlock do
  @moduledoc """
  Client-side WASM verification block. Shared between the static proof
  controller and the LiveView proof page.
  """
  use WallopWeb, :html

  attr(:draw, :map, required: true)
  attr(:entries_json, :string, required: true)
  attr(:results_json, :string, required: true)
  attr(:receipt, :map, default: nil)
  attr(:execution_receipt, :map, default: nil)
  attr(:operator_public_key_hex, :string, default: nil)
  attr(:infra_public_key_hex, :string, default: nil)

  def verify_block(assigns) do
    ~H"""
    <div class="bg-white border border-cream-border rounded-xl">
      <div class="p-5 space-y-4">
        <div
          id="verify-animation"
          data-verify
          data-draw-id={@draw.id}
          data-entry-count={@draw.entry_count || 0}
          data-entry-hash={@draw.entry_hash && String.slice(@draw.entry_hash, 0, 8)}
          data-entry-hash-full={@draw.entry_hash}
          data-seed={@draw.seed && String.slice(@draw.seed, 0, 8)}
          data-seed-full={@draw.seed}
          data-drand-round={@draw.drand_round}
          data-drand-randomness={@draw.drand_randomness}
          data-weather-value={@draw.weather_value}
          data-winner-count={length(@draw.results || [])}
          data-entries-json={@entries_json}
          data-results-json={@results_json}
          data-lock-receipt-jcs={@receipt && @receipt.payload_jcs}
          data-lock-signature-hex={@receipt && Base.encode16(@receipt.signature, case: :lower)}
          data-operator-public-key-hex={@operator_public_key_hex}
          data-execution-receipt-jcs={@execution_receipt && @execution_receipt.payload_jcs}
          data-execution-signature-hex={@execution_receipt && Base.encode16(@execution_receipt.signature, case: :lower)}
          data-infra-public-key-hex={@infra_public_key_hex}
        >
          <p data-verify-hint class="text-[10px] text-[#999] mb-1.5">
            Runs locally in your browser via WebAssembly. No server involved.
          </p>
          <button data-verify-btn class="btn btn-neutral btn-sm rounded-lg">
            Verify independently
          </button>
          <div
            data-verify-box
            class="text-[9px] sm:text-[12px]"
            style="display:none;background:#1a1a1a;color:#e4e4e4;padding:20px 24px;border-radius:12px;font-family:'SF Mono',Monaco,Consolas,monospace;line-height:2.2;border:2px solid #1a1a1a;margin-top:8px;"
          >
          </div>
        </div>

        <details class="text-[11px] text-[#666] border-t border-cream-border pt-3">
          <summary class="cursor-pointer font-medium text-[#444]">
            <span data-verify-mode-badge class="inline-flex items-center gap-1.5 bg-blue-50 text-blue-800 text-[10px] font-semibold px-2 py-0.5 rounded">
              Mode: local self-check only
            </span>
            <span class="ml-2">What does this verify?</span>
          </summary>
          <p class="mt-2 leading-relaxed">
            The browser-side check confirms the bundle's signatures and math
            agree with each other and with the keys embedded in the bundle
            itself. It catches accidents and casual tampering, but it does
            <em>not</em> defend against a tampered mirror or a compromised
            CDN — an attacker serving a forged bundle with their own keys
            would also pass every step. For full verification — bound to
            wallop's infrastructure key, where the trust root is the
            binary you installed, not the network you're talking to — run
            the CLI in attributable mode:
          </p>
          <pre class="mt-2 bg-[#1a1a1a] text-[#e2e8f0] p-3 rounded font-mono text-[10px] leading-[1.7] overflow-x-auto">{Phoenix.HTML.raw(~s(<span class="text-[#777]">$</span> cargo install wallop_verifier\n<span class="text-[#777]">$</span> wallop-verify --mode attributable \\\n    --wallop-base-url https://wallop.run \\\n    --pin-from-url https://wallop.run/operator/&lt;slug&gt;/keyring-pin.json \\\n    proof-bundle.json))}</pre>
          <p class="mt-2 leading-relaxed">
            See
            <a href="/how-verification-works" class="underline decoration-[#ccc] hover:decoration-[#1a1a1a]">how verification works</a>
            for the full picture, or the spec at
            <code class="font-mono text-[10px]">spec/protocol.md</code>
            §4.2.4.
          </p>
        </details>
      </div>
    </div>
    """
  end
end
