/**
 * Standalone draw verification using WASM.
 *
 * Works on both static (controller-rendered) and LiveView pages.
 * No LiveView hooks. The browser fetches the published proof bundle and
 * keys, and the wallop_verifier WASM module checks them locally. What
 * is checked, and the verdict, live in verify_core.js.
 */
import anime from "animejs/lib/anime.es.js"
import { GENERIC_RED, computeChecks, fetchPublishedProof, hasReceipts } from "./verify_core.js"

const VERDICT_COLOURS = { green: "#4ade80", amber: "#fbbf24", red: "#f87171" }

const COULDNT_RUN =
  "COULDN'T RUN — your browser couldn't load the checker, so nothing was verified. " +
  "Try another browser, or the command below."
const COULDNT_CHECK =
  "COULDN'T CHECK — the proof couldn't be fetched, so nothing was verified. Try again in a moment."
const AMBER = {
  none: "NOT FULLY VERIFIED — the draw maths agrees with this page, but this draw has no signed " +
    "receipts, so we can't confirm it wasn't changed afterwards. Nothing is wrong; there's just less to check.",
  partial: "NOT FULLY VERIFIED — the draw maths agrees with this page, but this draw's signed " +
    "receipts are incomplete, so we can't confirm it wasn't changed afterwards. Please tell the organiser."
}

// Lazy-loaded WASM module
let wasmModule = null
let wasmVersion = null

async function loadWasm() {
  if (wasmModule) return wasmModule
  const [wasm, pkg] = await Promise.all([
    import("/assets/wasm/wallop_verifier.js"),
    fetch("/assets/wasm/package.json").then(r => r.json()).catch(() => null)
  ])
  await wasm.default("/assets/wasm/wallop_verifier_bg.wasm")
  wasmModule = wasm
  wasmVersion = pkg && pkg.version ? `v${pkg.version}` : null
  return wasm
}

function scrambleText(el, target, duration) {
  const chars = "0123456789abcdef"
  let startTime = null

  return new Promise(resolve => {
    function frame(timestamp) {
      if (!startTime) startTime = timestamp
      let progress = Math.min((timestamp - startTime) / duration, 1)
      let revealed = Math.floor(progress * target.length)
      let text = target.substring(0, revealed)
      for (let i = revealed; i < target.length; i++) {
        text += chars[Math.floor(Math.random() * chars.length)]
      }
      el.textContent = text
      if (progress < 1) {
        requestAnimationFrame(frame)
      } else {
        el.textContent = target
        resolve()
      }
    }
    requestAnimationFrame(frame)
  })
}

function injectVerifyStyles() {
  if (document.getElementById("verify-runner-css")) return
  let style = document.createElement("style")
  style.id = "verify-runner-css"
  style.textContent = `
    .vrow {
      display: flex;
      align-items: baseline;
      gap: 10px;
      min-height: 24px;
    }
    .vmarker {
      color: #facc15;
      flex-shrink: 0;
    }
    .vtext {
      flex: 1;
    }
    .vmono {
      color: #4ade80;
      font-weight: 600;
    }
    .vsuffix {
      color: #666;
      font-size: 11px;
    }
    @media (max-width: 639px) {
      .vrow {
        display: block;
        padding-left: 16px;
        text-indent: -16px;
        min-height: 18px;
        line-height: 1.5;
      }
      .vmarker {
        display: inline;
        margin-right: 4px;
      }
      .vtext {
        text-indent: 0;
      }
      .vmono {
        display: inline;
        text-indent: 0;
        white-space: nowrap;
      }
      .vsuffix {
        font-size: 9px;
        text-indent: 0;
        white-space: nowrap;
        margin-left: 6px;
      }
    }
  `
  document.head.appendChild(style)
}

class VerifyRunner {
  constructor(el) {
    this.el = el
    this.btn = el.querySelector("[data-verify-btn]")
    this.box = el.querySelector("[data-verify-box]")
    injectVerifyStyles()

    if (this.btn) {
      this.btn.addEventListener("click", () => this.run())
    }
  }

  async run() {
    let d = this.el.dataset
    this.btn.style.display = "none"
    this.box.style.display = "block"
    this.box.innerHTML = ""

    anime({ targets: this.box, opacity: [0, 1], duration: 300, easing: "easeOutCubic" })

    let header = document.createElement("div")
    header.style.cssText = "color:#888;margin-bottom:14px;font-size:11px;letter-spacing:1px;text-transform:uppercase;"
    this.box.appendChild(header)
    await this.typeText(header, `Verifying draw #${d.drawId.substring(0, 8)}...`, 40)

    await this.runSteps(d)
  }

  async runSteps(d) {
    // Loading the verifier and fetching the published proof share one line.
    let line0 = this.addLine()
    await this.typeText(line0.text, "loading verifier (wallop_verifier.wasm)... ", 25)
    let wasm
    try {
      wasm = await loadWasm()
    } catch (e) {
      this.markFailed(line0)
      this.showResult("amber", COULDNT_RUN)
      return
    }

    let published = null
    if (hasReceipts(d)) {
      try {
        published = await fetchPublishedProof(d)
      } catch (e) {
        this.markFailed(line0)
        // A refused bundle (e.g. 500 proof_chain_incomplete) is a failed proof;
        // only a request that got no answer is "couldn't check".
        this.showResult(e.kind === "network" ? "amber" : "red", e.kind === "network" ? COULDNT_CHECK : GENERIC_RED)
        return
      }
    }
    this.markDone(line0, wasmVersion || "loaded")

    // Every decision is made here, gate first; the lines below only show it.
    let result
    try {
      result = computeChecks(wasm, d, published)
    } catch (e) {
      this.showResult("red", GENERIC_RED)
      return
    }
    if (result.fatal) {
      this.showResult("red", result.fatal)
      return
    }

    for (let check of result.lines) {
      let line = await this.showLine(check)
      // Shown values stay green only on a line that passed.
      if (line.mono && check.status !== "pass") line.mono.style.color = "#888"
      if (check.status === "fail") {
        this.markFailed(line)
        this.showResult("red", check.failMessage)
        return
      }
      if (check.status === "pass") this.markDone(line, check.passLabel)
      else this.markNeutral(line, check.status === "unconfirmed" ? "not confirmed (see result)" : "no receipt")
    }

    this.showVerdict(result)
  }

  async showLine(check) {
    let line = this.addLine()
    await this.typeText(line.text, check.text, check.typeSpeed || 25)
    if (check.waitLabel) this.startWaiting(line, check.waitLabel)
    if (check.kind === "count") {
      line.mono = this.addMono(line.row)
      await this.countUp(line.mono, parseInt(check.count), 1200)
      line.mono.textContent = check.mono
    } else if (check.mono) {
      line.mono = this.addMono(line.row)
      await scrambleText(line.mono, check.mono, check.scrambleMs || 1200)
    }
    return line
  }

  showVerdict(result) {
    if (result.verdict === "amber") {
      this.showResult("amber", AMBER[result.receiptState] || AMBER.none)
      return
    }
    if (result.verdict !== "green") {
      this.showResult("red", GENERIC_RED)
      return
    }
    this.showResult("green", "VERIFIED — everything we could check, checked out")
    if (result.fallbackLabel) this.addNote(result.fallbackLabel, "#facc15")
    this.addNote(
      `Checked against the signing keys ${window.location.host} publishes. Those come from the same ` +
      "place as this page, so for a check that doesn't rely on us, use the command below.",
      "#888")
    if (result.bmrsYear) {
      this.addNote(`Contains BMRS data © Elexon Limited copyright and database right ${result.bmrsYear}`, "#888")
    }
  }

  addNote(text, color) {
    let el = document.createElement("div")
    el.style.cssText = `color:${color};font-size:11px;line-height:1.6;margin-top:6px;`
    el.textContent = text
    this.box.appendChild(el)
  }

  addLine() {
    let row = document.createElement("div")
    row.className = "vrow"
    let marker = document.createElement("span")
    marker.className = "vmarker"
    marker.textContent = "▸"
    let text = document.createElement("span")
    text.className = "vtext"
    let suffix = document.createElement("span")
    suffix.className = "vsuffix"
    row.appendChild(marker)
    row.appendChild(text)
    row.appendChild(suffix)
    this.box.appendChild(row)
    return { row, marker, text, suffix }
  }

  addMono(row) {
    let mono = document.createElement("span")
    mono.className = "vmono"
    row.insertBefore(mono, row.lastChild)
    return mono
  }

  startWaiting(line, label) {
    line.suffix.style.color = "#444"
    let width = label ? label.length : 5
    let pos = 0
    let forward = true
    let tick = () => {
      let chars = Array(width).fill("-")
      chars[pos] = "_"
      line.suffix.textContent = chars.join("")
      if (forward) {
        pos++
        if (pos >= width - 1) forward = false
      } else {
        pos--
        if (pos <= 0) forward = true
      }
    }
    tick()
    line._waitInterval = setInterval(tick, 120)
  }

  stopWaiting(line) {
    if (line._waitInterval) {
      clearInterval(line._waitInterval)
      line._waitInterval = null
    }
    line.suffix.style.color = ""
  }

  markDone(line, label) {
    this.stopWaiting(line)
    line.marker.textContent = "✓"
    line.marker.style.color = "#4ade80"
    if (label) {
      line.suffix.textContent = label
    }
  }

  markFailed(line) {
    this.stopWaiting(line)
    line.marker.textContent = "✗"
    line.marker.style.color = "#f87171"
  }

  // Its own check held, but nothing signed backs it: no tick.
  markNeutral(line, label) {
    this.stopWaiting(line)
    line.marker.textContent = "–"
    line.marker.style.color = "#888"
    line.suffix.textContent = label
  }

  showResult(verdict, message) {
    let color = VERDICT_COLOURS[verdict] || VERDICT_COLOURS.red
    let el = document.createElement("div")
    el.style.cssText = `color:${color};font-weight:700;margin-top:14px;`
    el.textContent = message
    this.box.appendChild(el)
    anime({ targets: el, opacity: [0, 1], translateY: [8, 0], duration: 500, easing: "easeOutCubic" })
    anime({
      targets: this.box,
      borderColor: ["#1a1a1a", color, color, "#333"],
      duration: 1500,
      easing: "easeInOutCubic"
    })
  }

  typeText(el, text, speed) {
    return new Promise(resolve => {
      let i = 0
      let interval = setInterval(() => {
        el.textContent = text.substring(0, ++i)
        if (i >= text.length) {
          clearInterval(interval)
          resolve()
        }
      }, speed)
    })
  }

  countUp(el, target, duration) {
    let counter = { val: 0 }
    return new Promise(resolve => {
      anime({
        targets: counter,
        val: target,
        round: 1,
        duration: duration,
        easing: "easeOutCirc",
        update: () => { el.textContent = `${counter.val}/${target}` },
        complete: resolve
      })
    })
  }
}

// Auto-attach to any element with data-verify on page load and on LiveView updates
function attachVerifiers() {
  document.querySelectorAll("[data-verify]:not([data-verify-attached])").forEach(el => {
    el.setAttribute("data-verify-attached", "true")
    new VerifyRunner(el)
  })
}

// Run on initial load
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", attachVerifiers)
} else {
  attachVerifiers()
}

// Run on LiveView page updates (MutationObserver catches DOM changes)
new MutationObserver(attachVerifiers).observe(document.body, { childList: true, subtree: true })

export { VerifyRunner, attachVerifiers }
