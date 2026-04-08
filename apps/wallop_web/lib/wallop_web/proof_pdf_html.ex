defmodule WallopWeb.ProofPdfHTML do
  @moduledoc """
  Renders the proof PDF as a full HTML document with print-specific CSS.

  This is rendered by ChromicPDF (headless Chromium) into the final
  binary. All CSS is inlined, all fonts use the default Chromium system
  fonts, the only image is the Wallop logo which is served from the
  static assets directory (ChromicPDF can load local files by absolute
  path).

  Layout mirrors the certificate-style described in PAM-432:
  - Page 1: certificate front (logo, title, operator, summary, hashes)
  - Page 2: verification chain (entropy, seed, signed receipt)
  - Page 3+: full entries appendix
  - Final page: verification recipe
  """
  use Phoenix.Component

  @doc """
  Top-level render. Takes `assigns` from `WallopWeb.ProofPdf.generate/1`
  and returns a safe iolist / heex output suitable for feeding into
  Chromium.
  """
  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>Wallop Proof of Fair Draw</title>
        <style><%= Phoenix.HTML.raw(css()) %></style>
      </head>
      <body>
        <.certificate_page
          draw={@draw}
          operator={@operator}
          entries={@entries}
          public_url={@public_url}
          generated_at={@generated_at}
        />
        <.verification_chain_page
          draw={@draw}
          operator={@operator}
          receipt={@receipt}
        />
        <.entries_appendix entries={@entries} draw={@draw} />
        <.verification_recipe_page draw={@draw} public_url={@public_url} />
      </body>
    </html>
    """
  end

  attr(:draw, :map, required: true)
  attr(:operator, :map, default: nil)
  attr(:entries, :list, required: true)
  attr(:public_url, :string, required: true)
  attr(:generated_at, :any, required: true)

  defp certificate_page(assigns) do
    ~H"""
    <section class="page cert">
      <header class="cert-header">
        <div class="wordmark">Wallop!</div>
      </header>

      <h1 class="cert-title">Proof of Fair Draw</h1>

      <div :if={@draw.name} class="draw-name">{@draw.name}</div>

      <div :if={@operator} class="operator-line">
        Draw #<%= @draw.operator_sequence || "—" %> by
        <span class="operator-name">{@operator.name}</span>
        <span class="operator-slug">@{@operator.slug}</span>
      </div>

      <p class="summary">
        This draw selected
        <strong>{@draw.winner_count}</strong> {winner_word(@draw.winner_count)} from
        <strong>{length(@entries)}</strong> {entry_word(length(@entries))}
        using publicly verifiable entropy.
      </p>

      <dl class="fingerprints">
        <dt>Draw ID</dt>
        <dd class="mono">{@draw.id}</dd>

        <dt>Entry hash</dt>
        <dd class="mono wrap">{@draw.entry_hash || "—"}</dd>

        <dt>Seed (SHA-256)</dt>
        <dd class="mono wrap">{@draw.seed || "—"}</dd>

        <dt :if={@draw.executed_at}>Completed at</dt>
        <dd :if={@draw.executed_at}>
          {Calendar.strftime(@draw.executed_at, "%Y-%m-%d %H:%M:%S UTC")}
        </dd>
      </dl>

      <footer class="cert-footer">
        Verify online at
        <span class="mono">{@public_url}</span>
        · Generated {Calendar.strftime(@generated_at, "%Y-%m-%d %H:%M:%S UTC")}
      </footer>
    </section>
    """
  end

  attr(:draw, :map, required: true)
  attr(:operator, :map, default: nil)
  attr(:receipt, :map, default: nil)

  defp verification_chain_page(assigns) do
    ~H"""
    <section class="page">
      <h2>Verification chain</h2>

      <h3>Entry commitment</h3>
      <dl>
        <dt>Entry hash</dt>
        <dd class="mono wrap">{@draw.entry_hash || "—"}</dd>
        <dt>Canonical form</dt>
        <dd>JCS (RFC 8785) canonical JSON, SHA-256</dd>
      </dl>

      <h3>Drand entropy</h3>
      <dl>
        <dt>Chain</dt>
        <dd class="mono wrap">{@draw.drand_chain || "—"}</dd>
        <dt>Round</dt>
        <dd class="mono">{@draw.drand_round || "—"}</dd>
        <dt>Randomness</dt>
        <dd class="mono wrap">{@draw.drand_randomness || "—"}</dd>
        <dt>Signature</dt>
        <dd class="mono wrap">{@draw.drand_signature || "—"}</dd>
      </dl>

      <h3 :if={@draw.weather_value}>Weather entropy</h3>
      <dl :if={@draw.weather_value}>
        <dt>Station</dt>
        <dd>{@draw.weather_station || "—"}</dd>
        <dt>Observation time</dt>
        <dd>
          <%= if @draw.weather_observation_time do %>
            {Calendar.strftime(@draw.weather_observation_time, "%Y-%m-%d %H:%M:%S UTC")}
          <% else %>
            —
          <% end %>
        </dd>
        <dt>Value</dt>
        <dd class="mono">{@draw.weather_value}</dd>
      </dl>

      <div :if={@draw.weather_fallback_reason} class="note">
        <strong>Weather fallback:</strong>
        {@draw.weather_fallback_reason}. The seed was computed from drand entropy alone.
      </div>

      <h3>Seed</h3>
      <dl>
        <dt>Source</dt>
        <dd>{@draw.seed_source}</dd>
        <dt>Seed</dt>
        <dd class="mono wrap">{@draw.seed || "—"}</dd>
        <dt>Canonical JSON</dt>
        <dd class="mono wrap preblock">{@draw.seed_json || "—"}</dd>
      </dl>

      <h3 :if={@draw.results && @draw.results != []}>Winners</h3>
      <ol :if={@draw.results && @draw.results != []} class="winners">
        <li :for={winner <- @draw.results} class="mono">
          {winner_id(winner)}
        </li>
      </ol>

      <h3 :if={@receipt && @operator}>Operator receipt</h3>
      <dl :if={@receipt && @operator}>
        <dt>Operator</dt>
        <dd>
          {@operator.name} <span class="operator-slug">@{@operator.slug}</span>
        </dd>
        <dt>Sequence</dt>
        <dd class="mono">#{@receipt.sequence}</dd>
        <dt>Signing key</dt>
        <dd class="mono">{@receipt.signing_key_id}</dd>
        <dt>Locked at</dt>
        <dd>
          {Calendar.strftime(@receipt.locked_at, "%Y-%m-%d %H:%M:%S UTC")}
        </dd>
        <dt>Signed payload</dt>
        <dd class="mono wrap preblock">{@receipt.payload_jcs}</dd>
        <dt>Signature (base64)</dt>
        <dd class="mono wrap">{Base.encode64(@receipt.signature)}</dd>
      </dl>
    </section>
    """
  end

  attr(:entries, :list, required: true)
  attr(:draw, :map, required: true)

  defp entries_appendix(assigns) do
    ~H"""
    <section class="page">
      <h2>Entries</h2>
      <p class="hint">
        All {length(@entries)} entries included in this draw, exactly as committed
        to the <code>entry_hash</code> on the certificate page. Anonymised in the
        same format as the live proof page.
      </p>
      <ul class="entries mono">
        <li :for={entry <- @entries}>
          {anonymise(Map.get(entry, :id, ""))}
          <span :if={Map.get(entry, :weight, 1) != 1} class="weight">
            × {Map.get(entry, :weight, 1)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr(:draw, :map, required: true)
  attr(:public_url, :string, required: true)

  defp verification_recipe_page(assigns) do
    ~H"""
    <section class="page">
      <h2>How to verify this draw</h2>

      <ol class="recipe">
        <li>
          Fetch the drand beacon round
          <span class="mono">{@draw.drand_round || "—"}</span>
          from any drand relay (e.g. <code>https://api.drand.sh</code>). Confirm
          the randomness matches the value on the verification chain page.
        </li>
        <li :if={@draw.weather_value}>
          Fetch the Met Office Middle Wallop observation for
          {if @draw.weather_observation_time,
            do: Calendar.strftime(@draw.weather_observation_time, "%Y-%m-%d %H:%M UTC"),
            else: "the declared observation time"}.
          Confirm the temperature value matches.
        </li>
        <li>
          Canonicalise the entries list via JCS (RFC 8785), SHA-256 the bytes,
          and confirm the hash matches the entry hash on the certificate page.
        </li>
        <li>
          Combine entry hash, drand randomness, and weather value into a
          JCS-canonical JSON object and SHA-256 the bytes. Confirm the result
          matches the published seed.
        </li>
        <li>
          Run <code>fair_pick</code> (open source, published on Hex.pm) with the
          entries and seed. Confirm the selected winners match the list on the
          verification chain page.
        </li>
        <li>
          Cross-check the signed operator receipt (if present) against the
          operator's public key at
          <span class="mono">/operator/{"<slug>"}/key</span>
          and confirm it verifies.
        </li>
      </ol>

      <p class="hint">
        Full protocol details: <span class="mono">github.com/electric-lump-software/wallop</span>
      </p>

      <footer class="cert-footer">
        <p>
          Verified by an auditor or witness:
        </p>
        <div class="signature-line">Name __________________________ Signature __________________________ Date __________</div>
      </footer>
    </section>
    """
  end

  # Helpers -------------------------------------------------------------

  defp winner_word(1), do: "winner"
  defp winner_word(_), do: "winners"

  defp entry_word(1), do: "entry"
  defp entry_word(_), do: "entries"

  defp winner_id(%{"id" => id}), do: id
  defp winner_id(%{id: id}), do: id
  defp winner_id(id) when is_binary(id), do: id
  defp winner_id(_), do: ""

  # Match the live proof page's masking so the PDF is consistent with
  # what appears on screen. Dropped entirely once the entry identifier
  # refactor lands — see PAM-627.
  defp anonymise(""), do: ""

  defp anonymise(id) when is_binary(id) do
    case String.graphemes(id) do
      [] -> ""
      [first | _rest] -> first <> String.duplicate("•", min(byte_size(id) - 1, 12))
    end
  end

  defp anonymise(_), do: ""

  defp css do
    """
    @page {
      size: A4;
      margin: 20mm;
    }

    * { box-sizing: border-box; }

    html, body {
      margin: 0;
      padding: 0;
      background: #faf6ec;
      color: #1a1a1a;
      font-family: Georgia, 'Times New Roman', serif;
      font-size: 11pt;
      line-height: 1.55;
    }

    .page {
      page-break-after: always;
      min-height: 257mm;
      padding: 0;
    }

    .page:last-child {
      page-break-after: auto;
    }

    h1 { font-size: 32pt; font-weight: 900; margin: 40mm 0 8mm; text-align: center; letter-spacing: -0.01em; }
    h2 { font-size: 22pt; font-weight: 800; margin: 0 0 10mm; padding-bottom: 3mm; border-bottom: 2px solid #1a1a1a; }
    h3 { font-size: 13pt; font-weight: 700; margin: 8mm 0 3mm; text-transform: uppercase; letter-spacing: 0.08em; color: #555; }

    .cert {
      text-align: center;
    }

    .cert-header .wordmark {
      font-size: 48pt;
      font-weight: 900;
      letter-spacing: -0.02em;
      margin-bottom: 0;
    }

    .draw-name {
      font-size: 18pt;
      font-style: italic;
      margin: 4mm 0;
      color: #555;
    }

    .operator-line {
      font-size: 13pt;
      margin: 4mm 0 10mm;
    }

    .operator-name {
      font-weight: 700;
    }

    .operator-slug {
      font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 11pt;
      color: #888;
      margin-left: 0.4em;
    }

    .summary {
      font-size: 13pt;
      max-width: 140mm;
      margin: 8mm auto 14mm;
      line-height: 1.6;
    }

    dl {
      display: grid;
      grid-template-columns: 50mm 1fr;
      gap: 2mm 6mm;
      margin: 4mm 0;
    }

    dt {
      font-weight: 700;
      color: #555;
      font-size: 10pt;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      padding-top: 1mm;
    }

    dd {
      margin: 0;
      font-size: 11pt;
    }

    .cert dl {
      max-width: 150mm;
      margin: 10mm auto;
      text-align: left;
    }

    .mono {
      font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 9.5pt;
    }

    .wrap { word-break: break-all; }

    .preblock {
      white-space: pre-wrap;
      background: #fff;
      border: 1px solid #e6e0cf;
      padding: 3mm;
      border-radius: 2mm;
      font-size: 8.5pt;
    }

    .note {
      background: #fff8e1;
      border-left: 3px solid #d4a017;
      padding: 3mm 4mm;
      margin: 4mm 0;
      font-size: 10pt;
    }

    .winners {
      padding-left: 6mm;
      margin: 3mm 0;
    }

    .winners li {
      padding: 1.5mm 0;
      border-bottom: 1px dotted #ccc;
    }

    .entries {
      list-style: none;
      padding: 0;
      margin: 4mm 0;
      columns: 2;
      column-gap: 8mm;
    }

    .entries li {
      padding: 0.8mm 0;
      font-size: 9pt;
      break-inside: avoid;
    }

    .entries .weight {
      color: #888;
      font-size: 8pt;
    }

    .recipe {
      padding-left: 6mm;
      margin: 4mm 0;
    }

    .recipe li {
      margin-bottom: 4mm;
      padding-left: 2mm;
    }

    .hint {
      color: #666;
      font-size: 10pt;
      margin: 4mm 0;
    }

    .cert-footer {
      position: absolute;
      bottom: 20mm;
      left: 20mm;
      right: 20mm;
      text-align: center;
      font-size: 9pt;
      color: #888;
    }

    .cert-footer .signature-line {
      font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 9pt;
      margin-top: 4mm;
    }

    code {
      font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
      font-size: 9.5pt;
      background: #fff;
      border: 1px solid #e6e0cf;
      padding: 0.5mm 1.5mm;
      border-radius: 1mm;
    }
    """
  end
end
