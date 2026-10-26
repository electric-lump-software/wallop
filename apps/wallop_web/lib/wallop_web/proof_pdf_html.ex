defmodule WallopWeb.ProofPdfHTML do
  @moduledoc """
  Renders the proof PDF as a full HTML document with print-specific CSS.

  Fed to Gotenberg via `WallopWeb.ProofPdf.render_via_gotenberg/2` along
  with the `logo.png` asset as a sibling file in the same multipart
  request. The HTML references `<img src="logo.png">` and Gotenberg's
  Chromium resolves it from the multipart payload at render time.

  Layout mirrors the feedback on the first iteration:
  - Page 1: certificate front + winners (fits on one page for typical
    draws because there's space under the hashes)
  - Page 2: verification chain (entropy + seed)
  - Page 3: signed operator receipt (separate page because the payload
    is large)
  - Page 4: verification recipe + auditor signature block
  - Page 5+: entries appendix, last because its length is variable
  """
  use Phoenix.Component

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
        <.page_footer public_url={@public_url} generated_at={@generated_at} />
        <.certificate_page draw={@draw} operator={@operator} entries={@entries} />
        <.summary_page draw={@draw} winners={@winners} />
        <.verification_chain_page draw={@draw} weather={@weather} />
        <.signed_entropy_page :if={@weather} weather={@weather} />
        <.receipt_page operator={@operator} receipt={@receipt} :if={@receipt && @operator} />
        <.verification_recipe_page draw={@draw} weather={@weather} public_url={@public_url} />
        <.entries_appendix entries={@entries} />
      </body>
    </html>
    """
  end

  attr(:public_url, :string, required: true)
  attr(:generated_at, :any, required: true)

  defp page_footer(assigns) do
    ~H"""
    <footer class="page-footer">
      <div class="footer-line">
        Verify online at <span class="mono">{@public_url}</span>
      </div>
      <div class="footer-line">
        Generated {Calendar.strftime(@generated_at, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </footer>
    """
  end

  attr(:draw, :map, required: true)
  attr(:operator, :map, default: nil)
  attr(:entries, :list, required: true)

  defp certificate_page(assigns) do
    ~H"""
    <section class="page cert">
      <header class="wordmark">
        <img src="logo.png" alt="Wallop" class="logo" />
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
    </section>
    """
  end

  attr(:draw, :map, required: true)
  attr(:winners, :list, required: true)

  defp summary_page(assigns) do
    ~H"""
    <section class="page">
      <h2>Summary</h2>

      <dl>
        <dt>Draw ID</dt>
        <dd class="mono wrap">{@draw.id}</dd>

        <dt>Entry hash</dt>
        <dd class="mono wrap">{@draw.entry_hash || "—"}</dd>

        <dt>Seed (SHA-256)</dt>
        <dd class="mono wrap">{@draw.seed || "—"}</dd>

        <dt :if={@draw.executed_at}>Completed at</dt>
        <dd :if={@draw.executed_at}>
          {Calendar.strftime(@draw.executed_at, "%Y-%m-%d %H:%M:%S UTC")}
        </dd>
      </dl>

      <div :if={@winners != []} class="winners-block">
        <h3>Winners</h3>
        <ol class="winners">
          <li :for={w <- @winners}>
            <span class="pos">{w["position"]}</span>
            <span class="mono">{w["entry_id"]}</span>
          </li>
        </ol>
      </div>
    </section>
    """
  end

  attr(:draw, :map, required: true)
  attr(:weather, :map, default: nil)

  defp verification_chain_page(assigns) do
    ~H"""
    <section class="page">
      <h2>Verification chain</h2>

      <h3>Entry commitment</h3>
      <dl>
        <dt>Entry hash</dt>
        <dd class="mono wrap">{@draw.entry_hash || "—"}</dd>
        <dt>Canonical form</dt>
        <dd>JCS (RFC 8785), SHA-256</dd>
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

      <h3>Seed</h3>
      <dl>
        <dt>Source</dt>
        <dd>{@draw.seed_source}</dd>
        <dt>Seed</dt>
        <dd class="mono wrap">{@draw.seed || "—"}</dd>
        <dt>Canonical JSON</dt>
        <dd><pre class="mono preblock"><%= @draw.seed_json || "—" %></pre></dd>
      </dl>
    </section>
    """
  end

  attr(:weather, :map, required: true)

  # Lock schema 6 draws: what the signed receipts say, by the execution
  # receipt's state (`WallopWeb.ProofWeather`), never by the row's fields.
  # A page of its own, so the chain page keeps clear of the fixed footer.
  defp signed_entropy_page(assigns) do
    ~H"""
    <section class="page">
      <h2>Entropy source</h2>

      <p :if={@weather.source || @weather.observation_hour} class="hint">
        <strong>The signed receipt says:</strong>
      </p>

      <p :if={@weather.observation_hour} class="hint">
        Weather hour: {Calendar.strftime(@weather.observation_hour, "%Y-%m-%d %H:%M UTC")}.
        Set by the draw's drand round, so nobody gets to pick it.
      </p>

      <h3 :if={@weather.source == :weather}>Weather entropy</h3>
      <dl :if={@weather.source == :weather}>
        <dt>Station</dt>
        <dd>{@weather.station_label}</dd>
        <dt>Observation time</dt>
        <dd>{Calendar.strftime(@weather.observed_at, "%Y-%m-%d %H:%M:%S UTC")}</dd>
        <dt>Value</dt>
        <dd class="mono">{@weather.weather_value}</dd>
        <dt>Value parts</dt>
        <dd>temperature (°C × 10); pressure (hPa); humidity (%); visibility (m ÷ 10)</dd>
      </dl>

      <div :if={@weather.fallback_label} class="note">{@weather.fallback_label}</div>

      <h3 :if={@weather.source == :frequency}>Grid frequency entropy</h3>
      <dl :if={@weather.source == :frequency}>
        <dt>Readings (millihertz)</dt>
        <dd class="mono wrap">{@weather.freq_value}</dd>
        <dt :if={@weather.freq_start}>Window start (T)</dt>
        <dd :if={@weather.freq_start}>
          {Calendar.strftime(@weather.freq_start, "%Y-%m-%d %H:%M:%S UTC")}, eight readings 15 seconds apart
        </dd>
      </dl>
      <p :if={@weather.bmrs_line} class="hint">{@weather.bmrs_line}</p>

      <p :if={@weather.check_line} class="hint">{@weather.check_line}</p>

      <div :if={@weather.trust_lines != []} class="trust">
        <p class="hint">What you're trusting here:</p>
        <ul>
          <li :for={line <- @weather.trust_lines}>{line}</li>
        </ul>
      </div>

      <div :if={@weather.out_of_table} class="note">{@weather.out_of_table_text}</div>
    </section>
    """
  end

  attr(:operator, :map, required: true)
  attr(:receipt, :map, required: true)

  defp receipt_page(assigns) do
    ~H"""
    <section class="page">
      <h2>Signed operator receipt</h2>
      <p class="hint">
        Committed in the same transaction as the draw lock. Anyone can verify
        this receipt independently using the operator's public key.
      </p>

      <dl>
        <dt>Operator</dt>
        <dd>
          {@operator.name} <span class="operator-slug">@{@operator.slug}</span>
        </dd>
        <dt>Sequence</dt>
        <dd class="mono">#{@receipt.sequence}</dd>
        <dt>Signing key ID</dt>
        <dd class="mono">{@receipt.signing_key_id}</dd>
        <dt>Locked at</dt>
        <dd>
          {Calendar.strftime(@receipt.locked_at, "%Y-%m-%d %H:%M:%S UTC")}
        </dd>
      </dl>

      <h3>Signed payload (JCS)</h3>
      <pre class="mono preblock"><%= @receipt.payload_jcs %></pre>

      <h3>Signature (base64)</h3>
      <pre class="mono preblock"><%= Base.encode64(@receipt.signature) %></pre>
    </section>
    """
  end

  attr(:draw, :map, required: true)
  attr(:weather, :map, default: nil)
  attr(:public_url, :string, required: true)

  defp verification_recipe_page(assigns) do
    ~H"""
    <section class="page">
      <h2>How to verify this draw</h2>

      <ol class="recipe">
        <li>
          Fetch the drand beacon round
          <span class="mono">{@draw.drand_round || "—"}</span>
          from any drand relay (e.g. <span class="mono">https://api.drand.sh</span>).
          Confirm the randomness matches the value on the verification chain page.
        </li>
        <li :if={@weather && @weather.source == :weather}>
          Check that Middle Wallop's reading for
          {Calendar.strftime(@weather.observed_at, "%Y-%m-%d %H:%M UTC")} gives the value on
          the entropy source page (temperature, pressure, humidity and visibility). Within 48
          hours: Met Office Land Observations (free DataHub key). After that: temperature and
          pressure from a SYNOP mirror such as Ogimet, and every part from the Met Office MIDAS
          hourly archive on CEDA, released each July for the year before. Or run
          <span class="mono">wallop-verify weather-attest</span>
          on the proof bundle, which does this for you.
        </li>
        <li :if={@weather && @weather.source == :frequency}>
          Fetch Elexon's grid frequency readings (BMRS dataset FREQ) for T to T + 105 seconds,
          and confirm they match the readings on the verification chain page.
        </li>
        <li>
          Canonicalise the entries list via JCS (RFC 8785), SHA-256 the bytes,
          and confirm the hash matches the entry hash on the certificate page.
        </li>
        <li :if={@weather}>
          {seed_step(@weather.source)}
        </li>
        <li>
          Run <span class="mono">fair_pick</span> (open source, published on Hex.pm)
          with the entries and seed. Confirm the selected winners match the list
          on the certificate page.
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

      <p :if={check_url(@draw)} class="hint">
        The operator provides a ticket-check page at
        <span class="mono">{check_url(@draw)}</span>.
        Visit it to confirm whether your entry was submitted, see your
        position, or follow the operator's own post-draw process.
      </p>

      <div class="auditor">
        <p class="auditor-title">Verified by an auditor or witness</p>
        <div class="signature-grid">
          <div>
            <div class="sig-line"></div>
            <div class="sig-label">Name</div>
          </div>
          <div>
            <div class="sig-line"></div>
            <div class="sig-label">Signature</div>
          </div>
          <div>
            <div class="sig-line"></div>
            <div class="sig-label">Date</div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:entries, :list, required: true)

  defp entries_appendix(assigns) do
    ~H"""
    <section class="page appendix">
      <h2>Entries</h2>
      <p class="hint">
        All {length(@entries)} entries included in this draw, exactly as committed
        to the <span class="mono">entry_hash</span> on the certificate page.
      </p>
      <ul class="entries mono">
        <li :for={entry <- @entries}>
          {Map.get(entry, :uuid, "")}<span
            :if={Map.get(entry, :weight, 1) != 1}
            class="weight"
          >× {Map.get(entry, :weight, 1)}</span>
        </li>
      </ul>
    </section>
    """
  end

  # Helpers -------------------------------------------------------------

  defp winner_word(1), do: "winner"
  defp winner_word(_), do: "winners"

  # Extract the operator-supplied check_url from draw.metadata. Returns
  # Operator-supplied check_url, validated at Draw.create. Purely a
  # render-time lookup.
  defp check_url(%{check_url: url}) when is_binary(url), do: url
  defp check_url(_), do: nil

  defp entry_word(1), do: "entry"
  defp entry_word(_), do: "entries"

  defp css do
    """
    @page {
      size: A4;
      /* Bottom margin reserves room for the fixed page footer */
      margin: 20mm 18mm 15mm 18mm;
    }

    * { box-sizing: border-box; }

    html, body {
      margin: 0;
      padding: 0;
      background: #fffbf5;
      color: #1a1a1a;
      font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI",
                   Roboto, "Helvetica Neue", Arial, sans-serif;
      font-size: 13pt;
      line-height: 1.55;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }

    .page {
      page-break-after: always;
      break-after: page;
    }

    .page:last-child {
      page-break-after: auto;
      break-after: auto;
    }

    h1 {
      font-size: 38pt;
      font-weight: 900;
      margin: 12mm 0 6mm;
      text-align: center;
      letter-spacing: -0.01em;
    }

    h2 {
      font-size: 24pt;
      font-weight: 800;
      margin: 0 0 8mm;
      padding-bottom: 3mm;
      border-bottom: 2px solid #1a1a1a;
    }

    h3 {
      font-size: 12pt;
      font-weight: 700;
      margin: 8mm 0 3mm;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: #555;
    }

    .cert {
      text-align: center;
    }

    .wordmark {
      text-align: center;
      margin: 0;
    }

    .logo {
      height: 60mm;
      width: auto;
      display: inline-block;
    }

    .draw-name {
      font-size: 18pt;
      font-style: italic;
      margin: 3mm 0;
      color: #555;
    }

    .operator-line {
      font-size: 14pt;
      margin: 3mm 0 6mm;
    }

    .operator-name {
      font-weight: 700;
    }

    .operator-slug {
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      font-size: 12pt;
      color: #888;
      margin-left: 0.4em;
    }

    .summary {
      font-size: 14pt;
      max-width: 150mm;
      margin: 4mm auto 8mm;
      line-height: 1.55;
    }

    dl {
      display: grid;
      grid-template-columns: 50mm 1fr;
      gap: 3mm 6mm;
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
      font-size: 12pt;
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: break-word;
    }

    .cert .fingerprints {
      max-width: 160mm;
      margin: 6mm auto;
      text-align: left;
    }

    .mono {
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      font-size: 11pt;
      overflow-wrap: anywhere;
      word-break: break-all;
    }

    .wrap {
      overflow-wrap: anywhere;
      word-break: break-all;
    }

    .preblock {
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      word-break: break-all;
      background: #fff;
      border: 1px solid #e8e0d5;
      padding: 4mm 5mm;
      border-radius: 2mm;
      font-size: 10pt;
      margin: 2mm 0;
      max-width: 100%;
    }

    .trust li {
      font-size: 9.5pt;
      line-height: 1.45;
      margin-bottom: 1.5mm;
    }

    .note {
      background: #fff8e1;
      border-left: 3px solid #d4a017;
      padding: 3mm 4mm;
      margin: 4mm 0;
      font-size: 10pt;
    }

    .winners-block {
      max-width: 155mm;
      margin: 8mm auto 0;
      text-align: left;
    }

    .winners-block h3 {
      margin-top: 0;
    }

    .winners {
      list-style: none;
      padding: 0;
      margin: 2mm 0 0;
    }

    .winners li {
      display: flex;
      align-items: center;
      gap: 4mm;
      padding: 2mm 0;
      border-bottom: 1px dotted #d6ccb8;
    }

    .pos {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 8mm;
      height: 8mm;
      border-radius: 50%;
      background: #1a1a1a;
      color: #fff;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 10pt;
      font-weight: 700;
      flex-shrink: 0;
    }

    .entries {
      list-style: none;
      padding: 0;
      margin: 3mm 0;
      columns: 2;
      column-gap: 8mm;
    }

    .entries li {
      padding: 1mm 0;
      font-size: 11pt;
      break-inside: avoid;
      overflow-wrap: anywhere;
      word-break: break-all;
    }

    .entries .weight {
      color: #888;
      font-size: 10pt;
      margin-left: 0.4em;
    }

    .recipe {
      padding-left: 6mm;
      margin: 4mm 0;
    }

    .recipe li {
      margin-bottom: 5mm;
      padding-left: 2mm;
      line-height: 1.55;
    }

    .hint {
      color: #666;
      font-size: 12pt;
      margin: 3mm 0 5mm;
    }

    /* Fixed-position element repeats on every page in print mode in
       Chromium. Lives at the bottom of every page; CSS @page bottom
       margin reserves the room. */
    .page-footer {
      position: fixed;
      bottom: 4mm;
      left: 18mm;
      right: 18mm;
      text-align: center;
      font-size: 9pt;
      color: #888;
      line-height: 1.4;
      overflow-wrap: anywhere;
      word-break: break-all;
    }

    .footer-line {
      display: block;
      white-space: nowrap;
    }

    .auditor {
      margin-top: 18mm;
      padding: 6mm 5mm;
      border: 1px solid #e8e0d5;
      border-radius: 2mm;
      background: #fffbf5;
    }

    .auditor-title {
      margin: 0 0 6mm;
      text-align: center;
      font-size: 11pt;
      font-weight: 700;
      color: #555;
      text-transform: uppercase;
      letter-spacing: 0.06em;
    }

    .signature-grid {
      display: grid;
      grid-template-columns: 2fr 3fr 1.2fr;
      gap: 6mm;
    }

    .sig-line {
      border-bottom: 1px solid #888;
      height: 12mm;
    }

    .sig-label {
      margin-top: 1mm;
      font-size: 10pt;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: #888;
    }
    """
  end

  defp seed_step(:weather),
    do:
      "Combine entry hash, drand randomness and the weather value into a JCS-canonical " <>
        "JSON object and SHA-256 the bytes. Confirm the result matches the published seed."

  defp seed_step(:frequency),
    do:
      "Combine entry hash, drand randomness and the grid frequency readings (freq_value) into " <>
        "a JCS-canonical JSON object and SHA-256 the bytes. Confirm the result matches the " <>
        "published seed."

  defp seed_step(:drand_only),
    do:
      "Combine entry hash and drand randomness into a JCS-canonical JSON object and SHA-256 " <>
        "the bytes. Confirm the result matches the published seed."

  defp seed_step(nil),
    do:
      "The signed execution receipt names no seed source, so the seed can't be checked " <>
        "against it."
end
