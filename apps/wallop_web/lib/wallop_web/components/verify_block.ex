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
  attr(:operator_slug, :string, default: nil)
  attr(:verify_command, :map, default: nil)

  def verify_block(assigns) do
    assigns = assign(assigns, :key_unpublished?, key_unpublished?(assigns))

    ~H"""
    <div class="bg-white border border-cream-border rounded-xl">
      <div class="p-5 space-y-4">
        <p :if={@key_unpublished?} data-verify-unavailable class="text-[12px] text-[#444]">
          Cannot verify: signing key not published.
        </p>
        <div
          :if={!@key_unpublished?}
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
          data-bundle-url={~p"/proof/#{@draw.id}/json"}
          data-operator-keys-url={@receipt && @operator_slug && ~p"/operator/#{@operator_slug}/keys"}
          data-infra-keys-url={~p"/infrastructure/keys"}
        >
          <p data-verify-hint class="text-[10px] text-[#999] mb-1.5">
            Runs in your browser, using the proof and signing keys this site
            publishes. Nothing is sent to us.
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
              Mode: checked against published keys
            </span>
            <span class="ml-2">What does this verify?</span>
          </summary>
          <p class="mt-2 leading-relaxed">
            The browser-side check fetches the published proof bundle and
            checks its signatures and maths against the keys this site
            publishes. It catches accidents and tampering with the bundle,
            but the keys come from the same place as the bundle, so it
            <em>won't</em> protect you if someone copied this page and swapped
            in their own proof and keys.
          </p>
          <div :if={@verify_command}>
            <p :if={@verify_command.mode == :bundled} class="mt-2 leading-relaxed">
              For full verification, run the CLI in attributable mode. The
              infrastructure key it trusts is built into the binary you
              installed rather than fetched from the network you're talking to:
            </p>
            <p :if={@verify_command.mode == :self} class="mt-2 leading-relaxed">
              This instance's infrastructure keys aren't built into the
              verifier, so the command below supplies them with
              <code class="font-mono text-[10px]">--infra-key-pin</code>.
              It trusts this instance's own keys: it checks the bundle is
              consistent with what this instance publishes, not that it's
              authentic.
            </p>
            <pre class="mt-2 bg-[#1a1a1a] text-[#e2e8f0] p-3 rounded font-mono text-[10px] leading-[1.7] overflow-x-auto"><span class="text-[#777]">$</span> cargo install wallop_verifier --features cli
    <span class="text-[#777]">$</span> {Enum.join(@verify_command.lines, " \\\n    ")}</pre>
            <p class="mt-2 leading-relaxed">
              This command is a convenience, not a trust root — a page that
              can be tampered with can tamper with its own instructions. Get
              the verifier from crates.io and check the invocation against
              the docs.
            </p>
          </div>
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

  @doc """
  The page's results as JSON, in position order, the same order as the
  proof bundle, so the browser check compares like with like.
  """
  def results_json(nil), do: "[]"

  def results_json(results) when is_list(results) do
    results
    |> Enum.sort_by(&(&1["position"] || &1[:position]))
    |> Jason.encode!()
  end

  defp key_unpublished?(assigns) do
    (assigns.receipt != nil and assigns.operator_public_key_hex == nil) or
      (assigns.execution_receipt != nil and assigns.infra_public_key_hex == nil)
  end
end
