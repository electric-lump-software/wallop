defmodule WallopWeb.Components.OperatorPanel do
  @moduledoc """
  Components for showing operator and signed-receipt information on a proof
  page. Both render nothing when the draw has no operator (backward
  compatible).
  """
  use WallopWeb, :html

  attr(:operator, :map, default: nil)
  attr(:draw, :map, required: true)

  def operator_link(assigns) do
    ~H"""
    <div :if={@operator} class="text-sm">
      <a
        href={"/operator/#{@operator.slug}"}
        class="inline-flex flex-wrap items-baseline gap-x-1.5 text-[#555] hover:text-[#222]"
      >
        <span>Draw #{@draw.operator_sequence} by</span>
        <span class="font-semibold">{@operator.name}</span>
        <code class="text-xs text-[#888]">(@{@operator.slug})</code>
        <span aria-hidden="true">→</span>
      </a>
    </div>
    """
  end

  attr(:operator, :map, default: nil)
  attr(:receipt, :map, default: nil)

  def receipt_panel(assigns) do
    ~H"""
    <div :if={@receipt && @operator} class="bg-white border border-cream-border rounded-xl">
      <div class="p-5 space-y-3">
        <h3 class="text-lg font-bold">Operator commitment receipt</h3>
        <p class="text-xs text-[#555]">
          Signed at lock time with <code>{@operator.name}</code>'s Ed25519 key.
          Anyone can verify this receipt independently using the operator's
          public key. Listed in the public registry at
          <a href={"/operator/#{@operator.slug}"} class="link">/operator/{@operator.slug}</a>.
        </p>

        <div class="text-xs space-y-1">
          <div>
            <span class="text-[#888]">Sequence:</span>
            <span class="font-mono">#{@receipt.sequence}</span>
          </div>
          <div>
            <span class="text-[#888]">Signing key:</span>
            <span class="font-mono">{@receipt.signing_key_id}</span>
          </div>
          <div>
            <span class="text-[#888]">Locked at:</span>
            <span class="font-mono">
              {Calendar.strftime(@receipt.locked_at, "%Y-%m-%dT%H:%M:%S.%fZ")}
            </span>
          </div>
        </div>

        <details class="text-xs">
          <summary class="cursor-pointer text-[#555]">Signed payload (JCS)</summary>
          <pre class="mt-2 p-3 bg-base-200 rounded overflow-x-auto whitespace-pre-wrap break-all"><%= @receipt.payload_jcs %></pre>
        </details>

        <details class="text-xs">
          <summary class="cursor-pointer text-[#555]">Signature (base64)</summary>
          <pre class="mt-2 p-3 bg-base-200 rounded overflow-x-auto whitespace-pre-wrap break-all"><%= Base.encode64(@receipt.signature) %></pre>
        </details>

        <p class="text-xs text-[#555]">
          Public key:
          <a href={"/operator/#{@operator.slug}/key"} class="link">key</a>
          (raw 32 bytes) ·
          <a href={"/operator/#{@operator.slug}/keys"} class="link">all historical keys</a>
        </p>
      </div>
    </div>
    """
  end

  attr(:execution_receipt, :map, default: nil)
  attr(:operator, :map, default: nil)

  def execution_receipt_panel(assigns) do
    ~H"""
    <div :if={@execution_receipt} class="bg-white border border-cream-border rounded-xl">
      <div class="p-5 space-y-3">
        <h3 class="text-lg font-bold">Execution attestation</h3>
        <p class="text-xs text-[#555]">
          Signed after execution by the wallop infrastructure key.
          Attests to the entropy values, computed seed, and results.
          Verify independently using the
          <a href="/infrastructure/key" class="link">infrastructure public key</a>.
        </p>

        <div class="text-xs space-y-1">
          <div>
            <span class="text-[#888]">Sequence:</span>
            <span class="font-mono">#{@execution_receipt.sequence}</span>
          </div>
          <div>
            <span class="text-[#888]">Signing key:</span>
            <span class="font-mono">{@execution_receipt.signing_key_id}</span>
          </div>
          <div>
            <span class="text-[#888]">Lock receipt hash:</span>
            <span class="font-mono text-[10px]">{@execution_receipt.lock_receipt_hash}</span>
          </div>
        </div>

        <details class="text-xs">
          <summary class="cursor-pointer text-[#555]">Signed payload (JCS)</summary>
          <pre class="mt-2 p-3 bg-base-200 rounded overflow-x-auto whitespace-pre-wrap break-all"><%= @execution_receipt.payload_jcs %></pre>
        </details>

        <details class="text-xs">
          <summary class="cursor-pointer text-[#555]">Signature (base64)</summary>
          <pre class="mt-2 p-3 bg-base-200 rounded overflow-x-auto whitespace-pre-wrap break-all"><%= Base.encode64(@execution_receipt.signature) %></pre>
        </details>

        <p class="text-xs text-[#555]">
          Infrastructure key:
          <a href="/infrastructure/key" class="link">raw 32 bytes</a>
          (verify with <code>x-wallop-key-id</code> header)
        </p>
      </div>
    </div>
    <div :if={!@execution_receipt && @operator} class="bg-base-200 border border-cream-border rounded-xl p-5">
      <p class="text-xs text-[#888]">
        Execution attestation was not available at the time of this draw.
      </p>
    </div>
    """
  end
end
