# Wallop API Reference

Base URL: `https://<host>/api/v1`

All requests require `Authorization: Bearer <api_key>` header.
Content type: `application/vnd.api+json`

---

## Draw Lifecycle

```
create (open) → add entries → lock → [automatic] → completed
```

1. **Create** an open draw with `winner_count`
2. **Add entries** in batches (as many calls as needed)
3. **Lock** — freezes entries, declares entropy, and fixes when the result is due
4. Draw executes automatically when entropy is collected
5. **Webhook** fires to `callback_url` if provided

---

## Endpoints

### Create Draw

```
POST /draws
```

Creates an open draw. No entries yet.

**Request:**
```json
{
  "data": {
    "type": "draw",
    "attributes": {
      "winner_count": 2,
      "callback_url": "https://example.com/webhook",
      "metadata": {"raffle_id": "abc"}
    }
  }
}
```

- `winner_count` (required, integer 1-10000) — immutable after creation
- `callback_url` (optional, HTTPS only) — receives webhook on completion/failure
- `metadata` (optional, object) — stored but not used by Wallop

**Response:** Draw resource with `status: "open"`, empty `entries: []`

---

### Add Entries

```
PATCH /draws/:id/entries
```

Adds entries to an open draw. Can be called multiple times.

**Request:**
```json
{
  "data": {
    "type": "draw",
    "attributes": {
      "entries": [
        {"id": "ticket-001", "weight": 1},
        {"id": "ticket-002", "weight": 2}
      ]
    }
  }
}
```

- `entries` (required, array) — each entry has `id` (string) and `weight` (integer 1-1000)
- Duplicate IDs rejected (within batch and against existing entries)
- Maximum 10,000 total entries
- Draw must be in `open` status

**Response:** Updated draw resource with new entries appended

---

### Lock Draw

```
PATCH /draws/:id/lock
```

Freezes entries and starts entropy collection.

**Request:**
```json
{
  "data": {
    "type": "draw",
    "attributes": {}
  }
}
```

What else you may send depends on your operator's draw protocol. The platform sets the protocol per operator; it is `forecast` unless you've been moved. A draw keeps the protocol it was locked with, even if the setting changes afterwards.

| Protocol | Optional attribute | Rules |
|---|---|---|
| `forecast` (default) | `weather_time` | Whole seconds, at least 60 seconds ahead, within about 7 days. Without it, wallop picks a time 3–5 minutes after the lock. Sending `draw_at` is refused. |
| `observation` (observation weather) | `draw_at` | When the result is due: whole seconds, on drand quicknet's 3-second grid (any whole minute is), within 7 days. Without it, wallop picks the earliest allowed time. Sending `weather_time` is refused. |
| `frequency` (grid frequency) | `draw_at` | As for `observation`. |

**Preconditions:**
- Draw must be in `open` status
- At least 1 entry
- Entry count >= `winner_count`
- `observation`: the lock must happen by the observation hour of `draw_at` minus 46 minutes. For a 20:00 draw that is 18:14. From that latest lock time to the result is between 1h17m and 2h17m, depending on the draw minute.
- `frequency`: the lock must happen by 60 seconds before the first of the 8 grid-frequency readings, about 7 minutes before `draw_at`. For a 20:00:00 draw that is 19:53:00.

**What happens:**
1. Entry hash computed (SHA-256 of canonical entry list)
2. A drand round is declared:
   - `forecast`: the round published about 30 seconds before `weather_time`, and the weather value is fetched at `weather_time`;
   - `observation` and `frequency`: the round published at `draw_at`. The readings are fetched before that round exists, and the draw runs a few seconds after it.
3. Status transitions to `awaiting_entropy`
4. Draw executes automatically when its entropy is collected

**Response:** Draw resource with `status: "awaiting_entropy"`, `entry_hash`, `drand_round`, `weather_time`, `freq_start` and `expected_result_at`.

- `expected_result_at` — when the result is due: the publication time of the committed drand round, computed from `drand_round` and not signed. Equal to `draw_at` for `observation` and `frequency` draws; `null` for `forecast` draws.

**A lock that is too late** is refused with `400`, and the draw stays open. The error says when the draw had to be locked by, in `meta.latest_lock_at` (whole seconds, UTC). Other keys omitted:

```json
{
  "errors": [
    {
      "status": "400",
      "code": "invalid_argument",
      "detail": "is too late: this draw must be locked by 2026-10-14T18:14:00Z",
      "source": {"pointer": "/data/attributes/draw_at"},
      "meta": {"latest_lock_at": "2026-10-14T18:14:00Z"}
    }
  ]
}
```

Pick a later `draw_at` (or send none) and lock again. Without `draw_at` the error has no `source.pointer`. Match on `code` and `meta`, not on `detail`.

---

### Get Draw

```
GET /draws/:id
```

Returns the current state of a draw.

**Response:** Full draw resource including status, entries, results (if completed), entropy data, timestamps.

Entropy fields by protocol:

| Field | `forecast` | `observation` | `frequency` |
|---|---|---|---|
| `weather_station` | `middle-wallop` | `wmo-03749` | `null` |
| `weather_time` | When the forecast value is fetched | The observation hour | `null` |
| `weather_value`, `weather_observation_time`, `weather_fallback_reason` | Set by the draw | Set by the draw | `null` |
| `freq_start` | `null` | Start of the grid-frequency window used if Middle Wallop's reading is late | Start of the grid-frequency window |
| `freq_value`, `freq_fallback_reason` | `null` | Set only when Middle Wallop's reading was late | Set by the draw |
| `expected_result_at` | `null` | When the result is due | When the result is due |

`weather_station` on an observation-weather draw is always `wmo-03749` (Middle Wallop), whether the draw used Middle Wallop's reading, the grid frequency or drand alone. The signed execution receipt is the authority on which source was used. A completed observation-weather draw is in exactly one of three states:

- **weather:** `weather_value` set; `weather_fallback_reason`, `freq_value` and `freq_fallback_reason` `null`;
- **grid frequency:** `weather_fallback_reason` `no_observation_by_deadline`, `freq_value` set;
- **drand only:** `weather_fallback_reason` `no_observation_by_deadline`, `freq_fallback_reason` `no_frequency_by_deadline`.

Grid-frequency readings come from Elexon: Contains BMRS data © Elexon Limited copyright and database right [year], the year of the readings.

---

### List Draws

```
GET /draws
```

Returns the authenticated API key's draws, oldest first, one page at a time.

| Query parameter | Meaning |
|-----------------|---------|
| `status` | Optional. One status or a comma-separated list, e.g. `status=awaiting_entropy,pending_entropy`. Values are the statuses below, lower case; spaces around the commas are tolerated. Anything else is a `400` that names the parameter and the allowed values. `filter[...]` and `sort` are not accepted on this route (`400`). |
| `page[limit]` | Optional. 1 to 100, default 50. Above 100 is reduced to 100. |
| `page[after]` | Optional. A cursor taken from a previous response. Do not build these yourself. |

While more draws remain, the response carries `links.next`: a complete URL (filter and limit included) to fetch as it stands. On the last page the `next` key is still there, with the value `null`; when you see that, you have the lot. A page that happens to end exactly on the final draw also gives `null`, not an empty extra page.

Paging is by keyset, so it is not a snapshot. A draw created while you are paging can commit behind a cursor you were already handed and be missed until your next sweep. If you need to be sure, sweep again.

---

## Draw Statuses

| Status | Description |
|--------|-------------|
| `open` | Accepting entries. Mutable. |
| `locked` | Not seen in practice: locking a draw declares entropy in the same transaction, so a draw goes straight from `open` to `awaiting_entropy`. Still accepted as a `status` filter value (it is in the status enum), but it matches nothing. |
| `awaiting_entropy` | Entries locked. Waiting for entropy collection. |
| `pending_entropy` | Entropy collection in progress. |
| `completed` | Winners selected. Immutable. Terminal. |
| `failed` | Entropy collection failed (24h timeout). Terminal. |
| `expired` | Open draw abandoned (90 day timeout). Terminal. |

---

## Webhook

When a draw completes or fails, Wallop sends a POST to the `callback_url`:

```
POST <callback_url>
```

**Headers:**
```
Content-Type: application/json
X-Wallop-Signature: t=<unix_timestamp>,v1=<hmac_hex>
```

**Body:**
```json
{
  "draw_id": "uuid",
  "status": "completed"
}
```

**Verification:** Compute `HMAC-SHA256(webhook_secret, "#{timestamp}.#{body}")` and compare to `v1`.

The webhook secret is returned when the API key is created and cannot be retrieved again.

---

## Proof Page

Each draw has a public proof page at:

```
https://<host>/proof/:draw_id
```

This page shows:
- Real-time progress during open/in-progress draws
- Entry count and countdown timer
- Full verification record for completed draws (entry hash, entropy sources, seed, algorithm)
- Entry self-check form

The proof page requires no authentication — it's public by design.

---

## Authentication

API keys are managed through the Wallop web app. Each key provides:
- `key` — use as Bearer token (cannot be retrieved again)
- `key_prefix` — for identification
- `webhook_secret` — for HMAC verification of webhooks

---

## Error Responses

JSON:API error format:

```json
{
  "errors": [
    {
      "status": "400",
      "title": "InvalidBody",
      "detail": "description of error"
    }
  ]
}
```

Common errors:
- `401` — missing or invalid API key
- `403` — draw belongs to a different API key
- `400` — validation error (duplicate entries, draw not open, etc.)
- `404` — draw not found
- `429` — rate limited. The `Retry-After` header gives whole seconds to wait: at most 60 for per-key and per-IP limits. Every `429` carries it
