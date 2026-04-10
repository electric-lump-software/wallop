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
          data-lock-receipt-hash={@execution_receipt && @execution_receipt.lock_receipt_hash}
        >
          <p data-verify-hint class="text-[10px] text-[#999] mb-1.5">
            Runs locally in your browser via WebAssembly. No server involved.
          </p>
          <button data-verify-btn class="btn btn-neutral btn-sm rounded-lg">
            Verify independently
          </button>
          <div
            data-verify-box
            class="text-[9px] sm:text-[13px]"
            style="display:none;background:#1a1a1a;color:#e4e4e4;padding:20px 24px;border-radius:12px;font-family:'SF Mono',Monaco,Consolas,monospace;line-height:2.2;border:2px solid #1a1a1a;margin-top:8px;"
          >
          </div>
        </div>
      </div>
    </div>
    """
  end
end
