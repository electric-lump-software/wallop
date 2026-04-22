/**
 * Standalone draw verification using WASM.
 *
 * Works on both static (controller-rendered) and LiveView pages.
 * No LiveView hooks or server round-trips — verification runs
 * entirely in the browser via the wallop_verifier WASM module.
 */
import anime from "animejs/lib/anime.es.js"

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
    let entryCount = d.entryCount
    let entryHash = d.entryHash
    let seed = d.seed
    let drandRound = d.drandRound
    let weatherValue = d.weatherValue
    let winnerCount = d.winnerCount

    // Step 1: loading WASM
    let line0 = this.addLine()
    await this.typeText(line0.text, "loading verifier (wallop_verifier.wasm)... ", 25)
    let wasm
    try {
      wasm = await loadWasm()
      this.markDone(line0, wasmVersion || "loaded")
    } catch (e) {
      this.markFailed(line0)
      this.showError("Failed to load WASM verifier: " + e.message)
      return
    }

    // Step 2: entry_hash — independently computed
    let line1 = this.addLine()
    await this.typeText(line1.text, `entry_hash = SHA256(${entryCount} entries) → `, 25)
    this.startWaiting(line1, "match")
    let hash1 = this.addMono(line1.row)
    let computedEntryHashFull
    try {
      let ehEntries = JSON.parse(d.entriesJson).map(e => ({id: e.uuid, weight: e.weight}))
      let ehResult = wasm.entry_hash_wasm(d.drawId, ehEntries)
      // serde_wasm_bindgen may return a Map instead of a plain object
      computedEntryHashFull = ehResult instanceof Map ? ehResult.get("hash") : ehResult.hash
      await scrambleText(hash1, computedEntryHashFull.substring(0, 8), 1200)
      if (computedEntryHashFull !== d.entryHashFull) {
        this.markFailed(line1)
        this.showResult(false, "MISMATCH — computed entry_hash does not match stored value")
        return
      }
    } catch (e) {
      this.markFailed(line1)
      this.showError("Entry hash computation error: " + e.message)
      return
    }
    this.markDone(line1, "match")

    // Step 3: seed — independently computed
    let line2 = this.addLine()
    let seedLabel = weatherValue
      ? `seed = SHA256(hash, drand[${drandRound}], wx[${weatherValue}]) → `
      : `seed = SHA256(hash, drand[${drandRound}]) → `
    await this.typeText(line2.text, seedLabel, 20)
    this.startWaiting(line2, "match")
    let hash2 = this.addMono(line2.row)
    let computedSeedFull
    try {
      let seedResult = weatherValue
        ? wasm.compute_seed_wasm(computedEntryHashFull, d.drandRandomness, weatherValue)
        : wasm.compute_seed_drand_only_wasm(computedEntryHashFull, d.drandRandomness)
      computedSeedFull = seedResult instanceof Map ? seedResult.get("seed") : seedResult.seed
      await scrambleText(hash2, computedSeedFull.substring(0, 8), 1200)
      if (computedSeedFull !== d.seedFull) {
        this.markFailed(line2)
        this.showResult(false, "MISMATCH — computed seed does not match stored value")
        return
      }
    } catch (e) {
      this.markFailed(line2)
      this.showError("Seed computation error: " + e.message)
      return
    }
    this.markDone(line2, "match")

    // Step 4: draw
    let line3 = this.addLine()
    await this.typeText(line3.text, `winners = fair_pick.draw(${entryCount} entries, seed, ${winnerCount}) → `, 20)
    this.startWaiting(line3, "selected")
    let counter3 = this.addMono(line3.row)
    await this.countUp(counter3, parseInt(entryCount), 1200)
    counter3.textContent = `${winnerCount} winners`
    this.markDone(line3, "selected")

    // Step 5: verify_wasm (entries → results math)
    let line4 = this.addLine()
    await this.typeText(line4.text, "assert winners == stored_results → ", 25)

    let entriesJson = d.entriesJson
    let resultsJson = d.resultsJson
    let mathOk
    try {
      let entries = JSON.parse(entriesJson).map(e => ({id: e.uuid, weight: e.weight}))
      let expectedResults = JSON.parse(resultsJson)
      let count = parseInt(winnerCount)
      mathOk = wasm.verify_wasm(d.drawId, entries, d.drandRandomness, weatherValue || undefined, count, expectedResults)
    } catch (e) {
      this.markFailed(line4)
      this.showError("Verification error: " + e.message)
      return
    }
    if (!mathOk) {
      this.markFailed(line4)
      this.showResult(false, "MISMATCH — draw math verification failed")
      return
    }
    this.markDone(line4, "match")

    // Steps 6-10: receipt verification (only if receipt data is present)
    let hasReceipts = d.lockReceiptJcs && d.lockSignatureHex && d.operatorPublicKeyHex
                   && d.executionReceiptJcs && d.executionSignatureHex && d.infraPublicKeyHex

    if (hasReceipts) {
      // Step 6: verify lock receipt signature
      let line5 = this.addLine()
      await this.typeText(line5.text, "verify lock receipt (Ed25519) → ", 25)
      this.startWaiting(line5, "valid signature")
      let opKeyId = this.addMono(line5.row)
      let lockSigOk
      try {
        let kid = wasm.key_id_wasm(d.operatorPublicKeyHex)
        await scrambleText(opKeyId, kid, 600)
        lockSigOk = wasm.verify_receipt_wasm(d.lockReceiptJcs, d.lockSignatureHex, d.operatorPublicKeyHex)
      } catch (e) {
        this.markFailed(line5)
        this.showError("Lock receipt verification error: " + e.message)
        return
      }
      if (!lockSigOk) {
        this.markFailed(line5)
        this.showResult(false, "FAILED — lock receipt signature invalid")
        return
      }
      this.markDone(line5, "valid signature")

      // Step 7: binding check — lock receipt entry_hash matches computed
      let line6 = this.addLine()
      await this.typeText(line6.text, "lock receipt entry_hash binding → ", 25)
      try {
        let lockPayload = JSON.parse(d.lockReceiptJcs)
        let receiptEntryHash = lockPayload.entry_hash
        if (receiptEntryHash !== d.entryHashFull) {
          this.markFailed(line6)
          this.showResult(false, "MISMATCH — lock receipt entry_hash does not match computed hash")
          return
        }
      } catch (e) {
        this.markFailed(line6)
        this.showError("Failed to parse lock receipt: " + e.message)
        return
      }
      this.markDone(line6, "bound")

      // Step 8: verify execution receipt signature
      let line7 = this.addLine()
      await this.typeText(line7.text, "verify execution receipt (Ed25519) → ", 25)
      this.startWaiting(line7, "valid signature")
      let infraKeyId = this.addMono(line7.row)
      let execSigOk
      try {
        let kid = wasm.key_id_wasm(d.infraPublicKeyHex)
        await scrambleText(infraKeyId, kid, 600)
        execSigOk = wasm.verify_receipt_wasm(d.executionReceiptJcs, d.executionSignatureHex, d.infraPublicKeyHex)
      } catch (e) {
        this.markFailed(line7)
        this.showError("Execution receipt verification error: " + e.message)
        return
      }
      if (!execSigOk) {
        this.markFailed(line7)
        this.showResult(false, "FAILED — execution receipt signature invalid")
        return
      }
      this.markDone(line7, "valid signature")

      // Step 9: binding check — execution receipt seed + chain linkage
      let line8 = this.addLine()
      await this.typeText(line8.text, "lock_receipt_hash chain → ", 25)
      this.startWaiting(line8, "chain intact")
      let chainHash = this.addMono(line8.row)
      try {
        let execPayload = JSON.parse(d.executionReceiptJcs)
        if (execPayload.seed !== d.seedFull) {
          this.markFailed(line8)
          this.showResult(false, "MISMATCH — execution receipt seed does not match computed seed")
          return
        }
        let expectedLockHash = wasm.lock_receipt_hash_wasm(d.lockReceiptJcs)
        await scrambleText(chainHash, expectedLockHash.substring(0, 8), 800)
        if (execPayload.lock_receipt_hash !== expectedLockHash) {
          this.markFailed(line8)
          this.showResult(false, "MISMATCH — lock_receipt_hash chain is broken")
          return
        }
      } catch (e) {
        this.markFailed(line8)
        this.showError("Chain verification error: " + e.message)
        return
      }
      this.markDone(line8, "chain intact")

      // Step 9b: verify execution receipt results match computed results
      let line8b = this.addLine()
      await this.typeText(line8b.text, "execution receipt results binding → ", 25)
      try {
        let execPayload2 = JSON.parse(d.executionReceiptJcs)
        let receiptResults = JSON.stringify(execPayload2.results)
        let expectedResults = JSON.stringify(JSON.parse(resultsJson).map(r => r.entry_id))
        if (receiptResults !== expectedResults) {
          this.markFailed(line8b)
          this.showResult(false, "MISMATCH — execution receipt results do not match computed results")
          return
        }
      } catch (e) {
        this.markFailed(line8b)
        this.showError("Results binding error: " + e.message)
        return
      }
      this.markDone(line8b, "bound")

      // Step 10: verify_full_wasm — independent full pipeline double-check
      let line9 = this.addLine()
      await this.typeText(line9.text, "full pipeline double-check (verify_full_wasm) → ", 25)
      let fullOk
      try {
        fullOk = wasm.verify_full_wasm(
          d.lockReceiptJcs,
          d.lockSignatureHex,
          d.operatorPublicKeyHex,
          d.executionReceiptJcs,
          d.executionSignatureHex,
          d.infraPublicKeyHex,
          JSON.parse(entriesJson).map(e => ({id: e.uuid, weight: e.weight}))
        )
      } catch (e) {
        this.markFailed(line9)
        this.showError("Full pipeline verification error: " + e.message)
        return
      }
      if (!fullOk) {
        this.markFailed(line9)
        this.showResult(false, "FAILED — full pipeline verification disagreed")
        return
      }
      this.markDone(line9, "confirmed")
    }

    // Final result
    this.showResult(true, hasReceipts
      ? "VERIFIED — all checks passed, receipts valid, chain intact"
      : "VERIFIED — draw math confirmed (no receipt data for signature checks)")
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

  showResult(passed, message) {
    if (passed) {
      anime({
        targets: this.box,
        borderColor: ["#1a1a1a", "#4ade80", "#4ade80", "#333"],
        duration: 1500,
        easing: "easeInOutCubic"
      })
      let el = document.createElement("div")
      el.style.cssText = "color:#4ade80;font-weight:700;margin-top:14px;"
      el.textContent = message
      this.box.appendChild(el)
      anime({ targets: el, opacity: [0, 1], translateY: [8, 0], duration: 500, easing: "easeOutCubic" })
    } else {
      let el = document.createElement("div")
      el.style.cssText = "color:#f87171;font-weight:700;margin-top:14px;"
      el.textContent = message
      this.box.appendChild(el)
      anime({
        targets: this.box,
        borderColor: ["#1a1a1a", "#f87171", "#f87171", "#333"],
        duration: 1500,
        easing: "easeInOutCubic"
      })
    }
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
