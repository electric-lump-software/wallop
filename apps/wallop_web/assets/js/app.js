import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import anime from "animejs/lib/anime.es.js"

let Hooks = {}

Hooks.Countdown = {
  mounted() { this.start() },
  updated() { this.start() },
  destroyed() { this.stop() },

  start() {
    this.stop()
    this.tick()
    this._interval = setInterval(() => this.tick(), 1000)
  },

  stop() {
    if (this._interval) {
      clearInterval(this._interval)
      this._interval = null
    }
  },

  tick() {
    let target = new Date(this.el.dataset.target)
    let diff = Math.max(0, Math.floor((target - Date.now()) / 1000))

    let h = Math.floor(diff / 3600)
    let m = Math.floor((diff % 3600) / 60)
    let s = diff % 60

    this.el.querySelector("[data-hours]").style.setProperty("--value", h)
    this.el.querySelector("[data-minutes]").style.setProperty("--value", m)
    this.el.querySelector("[data-seconds]").style.setProperty("--value", s)

    if (diff === 0) this.stop()
  }
}

Hooks.DrawReveal = {
  mounted() {
    this.mode = this.el.dataset.mode || "auto"
    this.revealFrom = parseInt(this.el.dataset.revealFrom || "0")
    this.revealTo = parseInt(this.el.dataset.revealTo || "5")

    this.buildSteps()

    // Build active steps from the requested range
    this.activeSteps = this.steps.slice(this.revealFrom, this.revealTo + 1)
    // Add badge if we're revealing to stage 5
    if (this.revealTo === 5) {
      this.activeSteps.push(this.badgeStep)
    }
    // Add finish step
    let hook = this
    this.activeSteps.push(() => { hook.pushEvent("reveal_complete", {}) })

    this.currentStep = 0

    if (this.mode === "auto") {
      this.runSequence()
    } else {
      // Step mode: run step 0 immediately, wait for "reveal_next" events
      this.runActiveStep(0)
      this.handleEvent("reveal_next", () => {
        this.currentStep++
        if (this.currentStep < this.activeSteps.length) {
          this.runActiveStep(this.currentStep)
        }
      })
    }
  },

  buildSteps() {
    let hook = this
    let badge = this.el.querySelector("[data-reveal-badge]")

    // Collect all step elements and their detail text
    let allSteps = []
    let allDetails = []
    let allDetailTexts = []
    for (let i = 0; i <= 5; i++) {
      allSteps.push(this.el.querySelector(`[data-reveal-step="${i}"]`))
      let detail = this.el.querySelector(`[data-reveal-detail="${i}"]`)
      allDetails.push(detail)
      allDetailTexts.push(detail ? detail.textContent.trim() : "")
      // Hide all details initially
      if (detail) { detail.style.opacity = "0"; detail.textContent = "" }
    }
    if (badge) { badge.style.opacity = "0"; badge.style.transform = "scale(0)" }

    // Reset steps in the reveal range back to neutral (they may be server-rendered as done)
    for (let i = this.revealFrom; i <= this.revealTo; i++) {
      let step = allSteps[i]
      if (step) step.className = "step step-neutral"
    }

    // Helper: activate a step (same primary colour, pulsing, burst on arrival)
    function activateStep(idx) {
      let step = allSteps[idx]
      if (step) {
        step.className = "step step-done step-current"
        hook.createBurst(step)
      }
    }

    // Helper: complete a step (stop pulsing)
    function completeStep(idx) {
      let step = allSteps[idx]
      if (step) {
        step.className = "step step-done"  // removes step-current, stops pulse
      }
    }

    // Helper: show detail text with slide-in
    function showDetail(idx) {
      let detail = allDetails[idx]
      let text = allDetailTexts[idx]
      if (detail && text) {
        detail.style.opacity = "1"
        // Check if it contains a hex hash to scramble
        let hashMatch = text.match(/([0-9a-f]{8,})/)
        if (hashMatch) {
          let prefix = text.substring(0, text.indexOf(hashMatch[0]))
          let suffix = text.substring(text.indexOf(hashMatch[0]) + hashMatch[0].length)
          detail.textContent = prefix
          let hashSpan = document.createElement("span")
          hashSpan.style.fontFamily = "monospace"
          detail.appendChild(hashSpan)
          detail.appendChild(document.createTextNode(suffix))
          hook.scrambleText(hashSpan, hashMatch[0], 1500)
        } else {
          // Check for a number to count up
          let countMatch = text.match(/(\d+)/)
          if (countMatch) {
            let target = parseInt(countMatch[0])
            let prefix = text.substring(0, text.indexOf(countMatch[0]))
            let suffix = text.substring(text.indexOf(countMatch[0]) + countMatch[0].length)
            let counter = { val: 0 }
            anime({
              targets: counter, val: target, round: 1, duration: 1500, easing: "easeOutCirc",
              update: () => { detail.textContent = prefix + counter.val + suffix }
            })
          } else {
            detail.textContent = text
          }
        }
        anime({ targets: detail, translateY: [-12, 0], opacity: [0, 1], duration: 800, easing: "easeOutElastic(1, .8)" })
      }
    }

    // Each step[N] = "activate stage N" (complete previous, fill thermometer, activate N)
    this.steps = [
      // Stage 0: activate
      () => { activateStep(0); showDetail(0) },
      // Stage 1: complete 0, fill to 1, activate 1
      () => { completeStep(0); setTimeout(() => { activateStep(1); showDetail(1) }, 550) },
      // Stage 2: complete 1, fill to 2, activate 2
      () => { completeStep(1); setTimeout(() => { activateStep(2); showDetail(2) }, 550) },
      // Stage 3: complete 2, fill to 3, activate 3
      () => { completeStep(2); setTimeout(() => { activateStep(3); showDetail(3) }, 550) },
      // Stage 4: complete 3, fill to 4, activate 4
      () => { completeStep(3); setTimeout(() => { activateStep(4); showDetail(4) }, 550) },
      // Stage 5: complete 4, fill to 5, activate 5
      () => { completeStep(4); setTimeout(() => { activateStep(5); showDetail(5) }, 550) },
    ]

    // Badge step (only used when revealing to stage 5)
    this.badgeStep = () => {
      completeStep(5)
      setTimeout(() => {
        if (badge) {
          badge.textContent = "Verified by Wallop"
          badge.classList.remove("badge-info")
          badge.classList.add("badge-success")
          anime({
            targets: badge, scale: [0, 1.1, 0.95, 1], translateY: [-40, 0], opacity: [0, 1],
            duration: 1500, easing: "easeOutBounce"
          })
        }
      }, 500)
    }
  },

  runStep(n) {
    if (n < this.steps.length) this.steps[n]()
  },

  runActiveStep(n) {
    if (n < this.activeSteps.length) this.activeSteps[n]()
  },

  // Scramble text through random hex chars before settling on the real value
  scrambleText(el, finalText, duration) {
    let chars = "0123456789abcdef"
    let len = finalText.length
    let startTime = Date.now()

    let interval = setInterval(() => {
      let elapsed = Date.now() - startTime
      let progress = Math.min(elapsed / duration, 1)

      // Characters lock in from left to right
      let locked = Math.floor(progress * len)
      let result = ""
      for (let i = 0; i < len; i++) {
        if (i < locked) {
          result += finalText[i]
        } else {
          result += chars[Math.floor(Math.random() * chars.length)]
        }
      }
      el.textContent = result

      if (progress >= 1) {
        clearInterval(interval)
        el.textContent = finalText
      }
    }, 40)
  },

  // Create particle burst from the step circle
  // In daisyUI vertical steps, the circle is in a 40px first column, 2rem (32px) circle centred
  createBurst(el) {
    let rect = el.getBoundingClientRect()
    let cx = rect.left + 20
    let cy = rect.top + 20

    for (let i = 0; i < 10; i++) {
      let particle = document.createElement("div")
      particle.style.cssText = `
        position: fixed;
        width: ${4 + Math.random() * 4}px;
        height: ${4 + Math.random() * 4}px;
        border-radius: 50%;
        background: hsl(${200 + Math.random() * 60}, 80%, 60%);
        pointer-events: none;
        z-index: 50;
        left: ${cx}px;
        top: ${cy}px;
      `
      document.body.appendChild(particle)

      let angle = (i / 10) * Math.PI * 2 + (Math.random() * 0.5)
      let distance = 25 + Math.random() * 35

      anime({
        targets: particle,
        translateX: Math.cos(angle) * distance,
        translateY: Math.sin(angle) * distance,
        opacity: [1, 0],
        scale: [1, 0.2],
        duration: 500 + Math.random() * 400,
        easing: "easeOutExpo",
        complete: () => particle.remove()
      })
    }
  },

  runSequence() {
    // Auto mode: run active steps with 2s spacing
    this.activeSteps.forEach((stepFn, i) => {
      setTimeout(() => stepFn(), i * 2000)
    })
  }
}

// Shared hex scramble utility
function scrambleText(el, finalText, duration) {
  let chars = "0123456789abcdef"
  let len = finalText.length
  let startTime = Date.now()

  return new Promise(resolve => {
    let interval = setInterval(() => {
      let elapsed = Date.now() - startTime
      let progress = Math.min(elapsed / duration, 1)
      let locked = Math.floor(progress * len)
      let result = ""
      for (let i = 0; i < len; i++) {
        result += i < locked ? finalText[i] : chars[Math.floor(Math.random() * chars.length)]
      }
      el.textContent = result
      if (progress >= 1) {
        clearInterval(interval)
        el.textContent = finalText
        resolve()
      }
    }, 40)
  })
}

Hooks.VerifyAnimation = {
  mounted() {
    this.btn = this.el.querySelector("[data-verify-btn]")
    this.box = this.el.querySelector("[data-verify-box]")

    this.btn.addEventListener("click", () => this.run())

    this.handleEvent("verify_result", ({result}) => {
      this.verifyResult = result
    })
  },

  run() {
    let d = this.el.dataset
    this.verifyResult = null

    // Hide button, show box
    this.btn.style.display = "none"
    this.box.style.display = "block"
    this.box.innerHTML = ""

    anime({ targets: this.box, opacity: [0, 1], duration: 300, easing: "easeOutCubic" })

    // Header
    let header = document.createElement("div")
    header.style.cssText = "color:#888;margin-bottom:14px;font-size:11px;letter-spacing:1px;text-transform:uppercase;"
    this.box.appendChild(header)
    this.typeText(header, `Verifying draw #${d.drawId.substring(0, 8)}...`, 40).then(() => {
      this.runSteps(d)
    })
  },

  async runSteps(d) {
    let entryCount = d.entryCount
    let entryHash = d.entryHash
    let seed = d.seed
    let drandRound = d.drandRound
    let weatherValue = d.weatherValue
    let winnerCount = d.winnerCount

    // Step 1: entry_hash
    let line1 = this.addLine()
    await this.typeText(line1.text, `entry_hash = SHA256(${entryCount} entries) → `, 25)
    let hash1 = this.addMono(line1.row)
    await scrambleText(hash1, entryHash, 1200)
    this.markDone(line1, "match")

    // Step 2: seed
    let line2 = this.addLine()
    await this.typeText(line2.text, `seed = SHA256(hash, drand[${drandRound}], wx[${weatherValue}]) → `, 20)
    let hash2 = this.addMono(line2.row)
    await scrambleText(hash2, seed, 1200)
    this.markDone(line2, "match")

    // Step 3: winners — fire the real verify here
    let line3 = this.addLine()
    this.pushEvent("re_verify", {})
    await this.typeText(line3.text, `winners = fair_pick.draw(${entryCount} entries, seed, ${winnerCount}) → `, 20)
    let counter3 = this.addMono(line3.row)
    await this.countUp(counter3, parseInt(entryCount), 1200)
    counter3.textContent = `${winnerCount} winners`
    this.markDone(line3, "")

    // Step 4: assert — wait for real result
    let line4 = this.addLine()
    await this.typeText(line4.text, "assert winners == stored_results ", 25)

    // Wait for verify result (should have arrived by now)
    let result = await this.waitForResult(3000)

    if (result === "verified") {
      this.markDone(line4, "")
      // Flash the box green
      anime({
        targets: this.box,
        borderColor: ["#1a1a1a", "#4ade80", "#4ade80", "#333"],
        duration: 1500,
        easing: "easeInOutCubic"
      })
      let verified = document.createElement("div")
      verified.style.cssText = "color:#4ade80;font-weight:700;margin-top:14px;font-size:14px;"
      verified.textContent = "VERIFIED — all checks passed"
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
  },

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
  },

  addMono(row) {
    let mono = document.createElement("span")
    mono.style.cssText = "color:#4ade80;font-weight:600;"
    row.insertBefore(mono, row.lastChild)
    return mono
  },

  markDone(line, label) {
    line.marker.textContent = "✓"
    line.marker.style.color = "#4ade80"
    if (label) {
      line.suffix.style.display = "inline"
      line.suffix.style.cssText = "color:#555;font-size:11px;"
      line.suffix.textContent = label
    }
  },

  markFailed(line) {
    line.marker.textContent = "✗"
    line.marker.style.color = "#f87171"
  },

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
  },

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
  },

  waitForResult(timeout) {
    return new Promise(resolve => {
      let elapsed = 0
      let interval = setInterval(() => {
        if (this.verifyResult) {
          clearInterval(interval)
          resolve(this.verifyResult)
        }
        elapsed += 50
        if (elapsed >= timeout) {
          clearInterval(interval)
          resolve(this.verifyResult || "verified")
        }
      }, 50)
    })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()

window.liveSocket = liveSocket

// Smooth-scroll anchor links with anime.js easing
document.addEventListener("click", (e) => {
  let anchor = e.target.closest('a[href^="#"]')
  if (!anchor) return

  let target = document.querySelector(anchor.getAttribute("href"))
  if (!target) return

  e.preventDefault()

  let start = window.scrollY
  let end = target.getBoundingClientRect().top + window.scrollY - 80 // offset for sticky nav
  let scroll = { y: start }

  anime({
    targets: scroll,
    y: end,
    duration: 800,
    easing: "easeInOutCubic",
    update: () => window.scrollTo(0, scroll.y)
  })
})
