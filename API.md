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
3. **Lock** — freezes entries, declares entropy, starts ~10 min countdown
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

Freezes entries and starts entropy collection. No request body needed beyond the JSON:API wrapper.

**Request:**
```json
{
  "data": {
    "type": "draw",
    "attributes": {}
  }
}
```

**Preconditions:**
- Draw must be in `open` status
- At least 1 entry
- Entry count >= `winner_count`

**What happens:**
1. Entry hash computed (SHA-256 of canonical entry list)
2. drand round declared (~30s in the future)
3. Weather fetch scheduled (~10 min from now)
4. Status transitions to `awaiting_entropy`
5. Draw executes automatically when both entropy sources are collected

**Response:** Draw resource with `status: "awaiting_entropy"`, `entry_hash`, `drand_round`, `weather_time`

---

### Get Draw

```
GET /draws/:id
```

Returns the current state of a draw.

**Response:** Full draw resource including status, entries, results (if completed), entropy data, timestamps.

---

### List Draws

```
GET /draws
```

Returns the authenticated API key's draws, oldest first, one page at a time.

| Query parameter | Meaning |
|-----------------|---------|
| `status` | Optional. One status or a comma-separated list, e.g. `status=awaiting_entropy,pending_entropy`. Values are the statuses below, lower case. Anything else is a `400` that names the allowed values. |
| `page[limit]` | Optional. 1 to 100, default 50. Above 100 is reduced to 100. |
| `page[after]` | Optional. A cursor taken from a previous response. Do not build these yourself. |

While more draws remain, the response carries `links.next`: a complete URL (filter and limit included) to fetch as it stands. When `links.next` is `null`, you have the lot.

Paging is by keyset, so it is not a snapshot. A draw created while you are paging can commit behind a cursor you were already handed and be missed until your next sweep. If you need to be sure, sweep again.

---

## Draw Statuses

| Status | Description |
|--------|-------------|
| `open` | Accepting entries. Mutable. |
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
- `429` — rate limited. The `Retry-After` header gives whole seconds to wait: at most 60 for per-key and per-IP limits, longer for a monthly quota
