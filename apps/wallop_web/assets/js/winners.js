/**
 * Virtualised winners list.
 *
 * For draws with many winners (>100), the proof page renders a fixed-height
 * scroll container with the full winner list as a JSON data attribute.
 * This module hydrates that container into a windowed list — only rows in
 * the visible range (plus a small buffer) are mounted in the DOM at any time.
 *
 * Batches of 50 rows mount/unmount as the user scrolls.
 */

const ROW_HEIGHT = 36
const BATCH_SIZE = 50
const BUFFER_ROWS = 10

class VirtualWinners {
  constructor(el) {
    this.container = el
    this.spacer = el.querySelector("[data-virtual-spacer]")
    this.winners = JSON.parse(el.dataset.winnersJson || "[]")

    if (!this.winners.length) return

    // Set total height so scrollbar reflects full list
    this.spacer.style.height = `${this.winners.length * ROW_HEIGHT}px`

    // Track which rows are currently mounted
    this.mountedNodes = new Map()

    this.render = this.render.bind(this)
    this.container.addEventListener("scroll", this.render, { passive: true })
    this.render()
  }

  render() {
    const scrollTop = this.container.scrollTop
    const viewportHeight = this.container.clientHeight
    const total = this.winners.length

    // First and last visible row indexes
    const firstVisible = Math.floor(scrollTop / ROW_HEIGHT)
    const lastVisible = Math.ceil((scrollTop + viewportHeight) / ROW_HEIGHT)

    // Round to batch boundaries with buffer
    const start = Math.max(0, Math.floor((firstVisible - BUFFER_ROWS) / BATCH_SIZE) * BATCH_SIZE)
    const end = Math.min(total, Math.ceil((lastVisible + BUFFER_ROWS) / BATCH_SIZE) * BATCH_SIZE)

    // Unmount rows outside the new range
    for (const [index, node] of this.mountedNodes) {
      if (index < start || index >= end) {
        node.remove()
        this.mountedNodes.delete(index)
      }
    }

    // Mount rows inside the new range that aren't already mounted
    for (let i = start; i < end; i++) {
      if (!this.mountedNodes.has(i)) {
        const node = this.makeRow(this.winners[i], i)
        this.spacer.appendChild(node)
        this.mountedNodes.set(i, node)
      }
    }
  }

  makeRow(winner, index) {
    const row = document.createElement("div")
    row.className = "absolute left-0 right-0 flex items-center gap-3 px-4"
    row.style.top = `${index * ROW_HEIGHT}px`
    row.style.height = `${ROW_HEIGHT}px`

    const badge = document.createElement("span")
    badge.className =
      "inline-flex items-center justify-center w-6 h-6 bg-[#1a1a1a] text-white text-xs font-mono rounded-full shrink-0"
    badge.textContent = winner.position

    const id = document.createElement("span")
    id.className = "font-mono text-sm truncate"
    id.textContent = winner.entry_id

    row.appendChild(badge)
    row.appendChild(id)
    return row
  }
}

function attachVirtualWinners() {
  document.querySelectorAll("[data-virtual-winners]:not([data-virtual-attached])").forEach(el => {
    el.setAttribute("data-virtual-attached", "true")
    new VirtualWinners(el)
  })
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", attachVirtualWinners)
} else {
  attachVirtualWinners()
}

new MutationObserver(attachVirtualWinners).observe(document.body, { childList: true, subtree: true })

export { VirtualWinners, attachVirtualWinners }
