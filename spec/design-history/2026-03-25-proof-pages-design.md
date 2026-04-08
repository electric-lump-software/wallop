# Wallop Proof Pages Design

Sub-project 3 of 3. Public-facing LiveView pages for watching draws happen in real time and verifying results independently.

## Overview

Each draw gets a permanent public page at `/proof/:id`. During a live draw, connected viewers see real-time progress via Phoenix PubSub. After completion, the page becomes a permanent verification record with the full proof chain.

No authentication required — anyone with the URL can view the proof. Entry IDs are anonymised by default.

## Tech Stack

- Phoenix LiveView for real-time UI
- Tailwind CSS + daisyUI for styling and components
- Phoenix PubSub for broadcasting draw state changes

## URL Structure

`/proof/:id` where `:id` is the draw UUID. Distinct from the API paths (`/api/v1/draws/:id`).

## Page States

The proof page has three distinct views based on draw status:

### 1. Live Draw (awaiting_entropy / pending_entropy)

A vertical timeline/stepper showing progress through the draw stages:

```
✅ Entries Locked — 12 entries committed, hash: 6056fb...
✅ Entropy Declared — drand round #4812345, weather at 15:00 UTC
⏳ Fetching Entropy — waiting for drand round and weather observation...
○ Computing Seed
○ Selecting Winners
```

- Completed stages: green checkmark, detail text, timestamps
- Current stage: pulsing blue dot, status text
- Future stages: grey circles, label only
- Updates in real time for all connected viewers via PubSub

### 2. Completed Draw

Verification-first layout, scrolling top to bottom:

1. **"Verified by Wallop" badge** — prominent green verification indicator
2. **Draw metadata** — ID, completion timestamp
3. **Winners** — ordered list with anonymised entry IDs (first + last character, e.g. `t*****7`)
4. **How to verify (proof chain):**
   - ① Entry Hash — the SHA256 commitment hash
   - ② Entropy Sources — drand randomness + weather value, each with external verification links (drand.love, Met Office)
   - ③ Seed Computation — JCS formula showing how the three inputs combine
   - ④ Algorithm — fair_pick version with link to source code on GitHub
5. **Actions:**
   - "Re-verify" button — server-side: re-runs algorithm, confirms results match
   - "Check my entry" — form: submit full entry ID, confirms whether you won
   - "Verify locally" link — points to fair_pick GitHub repo with instructions

### 3. Failed Draw

Similar to completed but with failure messaging:
- Red badge instead of green
- Failure reason displayed
- Entropy source links still shown (for the sources that were declared)
- No winners section

## Entry Anonymisation

Entry IDs are partially masked on the public proof page:

| Full ID | Displayed as |
|---------|-------------|
| `ticket-47` | `t*****7` |
| `a` | `a` (too short to mask) |
| `ab` | `ab` (too short to mask) |
| `abc` | `a*c` |

Rule: show only the first character, replace the rest with a fixed-width mask of 6 asterisks regardless of actual ID length. This prevents leaking the ID length or last character, which could make structured IDs (like `ticket-47`) reversible.

| Full ID | Displayed as |
|---------|-------------|
| `ticket-47` | `t******` |
| `a` | `a******` |
| `abc` | `a******` |
| `entry-1234` | `e******` |

The full entry list is only available via the authenticated API (`GET /api/v1/draws/:id`).

### Entry Self-Check

A form on the proof page where a participant can verify their own entry:
1. User enters their full entry ID
2. Server checks if that ID is in the draw's entry list
3. If found: shows whether they won and their position (if winner)
4. If not found: "Entry not found in this draw"

This does NOT reveal other entries — only confirms the submitted ID.

**Rate limiting:** 10 checks per minute per draw per IP. Prevents brute-force enumeration of entry lists. API consumers (e.g. PAM) should use non-guessable entry IDs (UUIDs preferred) as an additional safeguard.

## Real-Time Updates

### PubSub Integration

When the EntropyWorker changes a draw's state, it broadcasts:

```elixir
Phoenix.PubSub.broadcast(WallopWeb.PubSub, "draw:#{draw_id}", {:draw_updated, draw})
```

Broadcast points:
- `awaiting_entropy → pending_entropy` — "Fetching entropy..."
- `pending_entropy → completed` — results available
- `pending_entropy → failed` — failure reason

### LiveView Subscription

```elixir
def mount(%{"id" => id}, _session, socket) do
  case load_draw(id) do
    {:ok, draw} ->
      if connected?(socket) do
        Phoenix.PubSub.subscribe(WallopWeb.PubSub, "draw:#{id}")
      end
      {:ok, assign(socket, draw: draw, draw_id: id)}

    {:error, :not_found} ->
      {:ok, redirect(socket, to: "/404")}
  end
end

def handle_info({:draw_updated, draw}, socket) do
  # Only accept updates for the draw we're subscribed to
  if draw.id == socket.assigns.draw_id do
    {:noreply, assign(socket, :draw, draw)}
  else
    {:noreply, socket}
  end
end
```

## Re-verify Feature

Server-side verification on button click:

1. Load the draw's stored entries, seed, and results
2. Re-run `FairPick.draw(entries, seed, winner_count)`
3. Compare computed results with stored results
4. Display: "Results verified — algorithm output matches stored results" or "Mismatch detected"

This verifies the stored data is self-consistent. The response is boolean only — "Results verified" or "Verification failed — please report this draw ID." No intermediate computation, raw values, or diffs are exposed on mismatch.

For full independent verification, the user follows the "verify locally" instructions using the open source fair_pick package.

## Project Structure

### Dependencies to add (wallop_web)

- `phoenix_live_view` (likely already via phoenix)
- `ash_phoenix` — Ash helpers for Phoenix/LiveView
- daisyUI via npm/Tailwind plugin config

### New files

| File | Responsibility |
|------|---------------|
| `apps/wallop_web/lib/wallop_web/live/proof_live.ex` | Main LiveView for proof pages |
| `apps/wallop_web/lib/wallop_web/live/proof_live.html.heex` | Template for the proof page |
| `apps/wallop_web/lib/wallop_web/components/draw_timeline.ex` | Timeline component (live draw stages) |
| `apps/wallop_web/lib/wallop_web/components/proof_chain.ex` | Proof chain component (verification steps) |
| `apps/wallop_web/lib/wallop_web/components/winner_list.ex` | Anonymised winner list component |
| `apps/wallop_web/lib/wallop_web/components/entry_check.ex` | Entry self-check form component |
| `apps/wallop_web/lib/wallop_web/components/layouts.ex` | Layout components (root, app) |
| `apps/wallop_web/lib/wallop_web/components/layouts/root.html.heex` | Root HTML layout with Tailwind + daisyUI |
| `apps/wallop_web/lib/wallop_web/components/layouts/app.html.heex` | App layout |
| `apps/wallop_core/lib/wallop_core/proof.ex` | Proof logic: anonymisation, re-verify, entry check |

### Modified files

| File | Changes |
|------|---------|
| `apps/wallop_web/lib/wallop_web/router.ex` | Add `/proof/:id` live route (no auth pipeline) |
| `apps/wallop_web/lib/wallop_web/endpoint.ex` | Add LiveView socket |
| `apps/wallop_core/lib/wallop_core/entropy/entropy_worker.ex` | Add PubSub broadcast on state changes |
| `apps/wallop_core/lib/wallop_core/application.ex` | Add PubSub to supervisor |
| `apps/wallop_web/mix.exs` | Add Tailwind/daisyUI config |
| `config/config.exs` | PubSub config |

### Tailwind + daisyUI Setup

Add daisyUI as a Tailwind plugin. Configure in `assets/tailwind.config.js`:

```js
module.exports = {
  plugins: [require("daisyui")],
  daisyui: {
    themes: ["light", "dark"],
  }
}
```

## Testing Strategy

| Layer | What to test |
|-------|-------------|
| Proof logic | Anonymisation (various ID lengths), re-verify (matches stored results), entry self-check (found/not found, winner/non-winner) |
| LiveView | Mount loads draw, PubSub updates re-render, completed view shows proof chain, failed view shows error |
| Timeline component | Correct stages rendered for each draw status |
| Entry check | Form submission, correct response for valid/invalid entries |
| Re-verify | Button click triggers verification, displays result |

LiveView tests use `Phoenix.LiveViewTest`. Proof logic tests are plain unit tests.

## Deferred

- Client-side WASM/JS verification (future card)
- Custom branding / white-label themes
- Marketing site
- Short URLs / vanity codes
