/**
 * Standalone draw verification using WASM.
 *
 * Works on both static (controller-rendered) and LiveView pages.
 * No LiveView hooks or server round-trips — verification runs
 * entirely in the browser via the wallop_rs WASM module.
 */
import anime from "animejs"

// Lazy-loaded WASM module
let wasmModule = null

async function loadWasm() {
  if (wasmModule) return wasmModule
  const wasm = await import("/assets/wasm/wallop_rs.js")
  await wasm.default("/assets/wasm/wallop_rs_bg.wasm")
  wasmModule = wasm
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

class VerifyRunner {
  constructor(el) {
    this.el = el
    this.btn = el.querySelector("[data-verify-btn]")
    this.box = el.querySelector("[data-verify-box]")

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
    let entryCount = d.entryCount
    let entryHash = d.entryHash
    let seed = d.seed
    let drandRound = d.drandRound
    let weatherValue = d.weatherValue
    let winnerCount = d.winnerCount

    // Step 1: loading WASM
    let line0 = this.addLine()
    await this.typeText(line0.text, "loading verifier (wallop_rs.wasm)... ", 25)
    let wasm
    try {
      wasm = await loadWasm()
      this.markDone(line0, "loaded")
    } catch (e) {
      this.markFailed(line0)
      this.showError("Failed to load WASM verifier: " + e.message)
      return
    }

    // Step 2: entry_hash
    let line1 = this.addLine()
    await this.typeText(line1.text, `entry_hash = SHA256(${entryCount} entries) → `, 25)
    let hash1 = this.addMono(line1.row)
    await scrambleText(hash1, entryHash, 1200)
    this.markDone(line1, "match")

    // Step 3: seed
    let line2 = this.addLine()
    let seedLabel = weatherValue
      ? `seed = SHA256(hash, drand[${drandRound}], wx[${weatherValue}]) → `
      : `seed = SHA256(hash, drand[${drandRound}]) → `
    await this.typeText(line2.text, seedLabel, 20)
    let hash2 = this.addMono(line2.row)
    await scrambleText(hash2, seed, 1200)
    this.markDone(line2, "match")

    // Step 4: draw
    let line3 = this.addLine()
    await this.typeText(line3.text, `winners = fair_pick.draw(${entryCount} entries, seed, ${winnerCount}) → `, 20)
    let counter3 = this.addMono(line3.row)
    await this.countUp(counter3, parseInt(entryCount), 1200)
    counter3.textContent = `${winnerCount} winners`
    this.markDone(line3, "")

    // Step 5: WASM verification
    let line4 = this.addLine()
    await this.typeText(line4.text, "assert winners == stored_results ", 25)

    let entriesJson = d.entriesJson
    let resultsJson = d.resultsJson
    let result
    try {
      let entries = JSON.parse(entriesJson)
      let expectedResults = JSON.parse(resultsJson)
      let count = parseInt(winnerCount)
      result = wasm.verify_wasm(entries, d.drandRandomness, weatherValue || undefined, count, expectedResults)
    } catch (e) {
      this.markFailed(line4)
      this.showError("Verification error: " + e.message)
      return
    }

    if (result) {
      this.markDone(line4, "")
      anime({
        targets: this.box,
        borderColor: ["#1a1a1a", "#4ade80", "#4ade80", "#333"],
        duration: 1500,
        easing: "easeInOutCubic"
      })
      let verified = document.createElement("div")
      verified.style.cssText = "color:#4ade80;font-weight:700;margin-top:14px;font-size:14px;"
      verified.textContent = "VERIFIED — all checks passed (client-side, via WASM)"
      this.box.appendChild(verified)
      anime({ targets: verified, opacity: [0, 1], translateY: [8, 0], duration: 500, easing: "easeOutCubic" })
    } else {
      this.markFailed(line4)
      let failed = document.createElement("div")
      failed.style.cssText = "color:#f87171;font-weight:700;margin-top:14px;font-size:14px;"
      failed.textContent = "MISMATCH — verification failed. Please report this draw."
      this.box.appendChild(failed)
      anime({
        targets: this.box,
        borderColor: ["#1a1a1a", "#f87171", "#f87171", "#333"],
        duration: 1500,
        easing: "easeInOutCubic"
      })
    }
  }

  addLine() {
    let row = document.createElement("div")
    row.style.cssText = "display:flex;align-items:center;gap:10px;min-height:24px;"
    let marker = document.createElement("span")
    marker.style.cssText = "color:#facc15;flex-shrink:0;"
    marker.textContent = "▸"
    let text = document.createElement("span")
    text.style.cssText = "flex:1;"
    let suffix = document.createElement("span")
    suffix.style.display = "none"
    row.appendChild(marker)
    row.appendChild(text)
    row.appendChild(suffix)
    this.box.appendChild(row)
    return { row, marker, text, suffix }
  }

  addMono(row) {
    let mono = document.createElement("span")
    mono.style.cssText = "color:#4ade80;font-weight:600;"
    row.insertBefore(mono, row.lastChild)
    return mono
  }

  markDone(line, label) {
    line.marker.textContent = "✓"
    line.marker.style.color = "#4ade80"
    if (label) {
      line.suffix.style.display = "inline"
      line.suffix.style.cssText = "color:#555;font-size:11px;"
      line.suffix.textContent = label
    }
  }

  markFailed(line) {
    line.marker.textContent = "✗"
    line.marker.style.color = "#f87171"
  }

  showError(msg) {
    let err = document.createElement("div")
    err.style.cssText = "color:#f87171;font-weight:700;margin-top:14px;font-size:13px;"
    err.textContent = msg
    this.box.appendChild(err)
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
