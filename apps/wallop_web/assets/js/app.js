import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()

window.liveSocket = liveSocket
