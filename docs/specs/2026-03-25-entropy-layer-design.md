# Wallop Entropy Layer Design

Sub-project 2 of 3. Adds automatic entropy fetching, draw execution, and webhook notifications.

## Overview

Draws created without a caller-provided seed are automatically executed using entropy from two independent public sources: the drand randomness beacon and Met Office weather observations. Results are delivered via signed webhook callbacks.

## State Machine

```
locked → completed                                       (caller seed, only if drand_round is nil)
locked → awaiting_entropy → pending_entropy → completed  (entropy path)
locked → awaiting_entropy → pending_entropy → failed     (entropy unavailable after 2h, or permanent error)
```

**States:**
- `locked` — entries committed, execution method not yet determined
- `awaiting_entropy` — entropy sources declared (drand round, weather time), Oban job scheduled, waiting for weather time to pass
- `pending_entropy` — Oban job actively fetching entropy sources
- `completed` — terminal, immutable, results stored
- `failed` — terminal, immutable, entropy unavailable after retries

**Mutual exclusivity:** If `drand_round` is set on a draw, the caller-provided seed path is blocked. Enforced at Ash policy level and DB trigger level.

**`pending_entropy` only set by internal Oban job**, never by API-facing actions.

**`failed` draws are not retryable.** Caller must create a new draw.

## New Draw Fields

| Field | Type | Set when | Notes |
|-------|------|----------|-------|
| `drand_chain` | `:string` | lock | Chain hash (hex), e.g. quicknet |
| `drand_round` | `:integer` | lock | Declared future round number |
| `drand_randomness` | `:string` | execute | 64-char hex from drand |
| `drand_signature` | `:string` | execute | BLS signature for verification |
| `drand_response` | `:string` | execute | Full drand API response (text, not JSONB — preserves byte-exact response) |
| `weather_station` | `:string` | lock | Station identifier |
| `weather_time` | `:utc_datetime_usec` | lock | Declared future observation hour |
| `weather_value` | `:string` | execute | Normalized integer string (round half-up via Decimal) |
| `weather_raw` | `:string` | execute | Full Met Office API response (text, not JSONB — preserves byte-exact response) |
| `callback_url` | `:string` | lock | Optional, must be HTTPS, no private IPs |
| `failed_at` | `:utc_datetime_usec` | failure | When the draw failed |
| `failure_reason` | `:string` | failure | Why it failed |

**Note:** `drand_response` and `weather_raw` are stored as text, not JSONB. PostgreSQL normalizes JSONB (reorders keys, removes whitespace), which would destroy the byte-exact API response needed for independent verification.

## New ApiKey Field

| Field | Type | Notes |
|-------|------|-------|
| `webhook_secret` | `:string` | Encrypted at rest via Cloak.Ecto. Generated alongside API key, returned once. Used for HMAC-SHA256 webhook signing. |

## Status Field Update

Update `:status` constraints from `[:locked, :completed]` to `[:locked, :awaiting_entropy, :pending_entropy, :completed, :failed]`.

## Entropy Clients

### DrandClient

- Fetches from drand relays with automatic failover on transport/5xx errors
- Relay order: `api.drand.sh`, `drand.cloudflare.com`, `api2.drand.sh`, `api3.drand.sh`
- Does NOT failover on 404 (round not yet produced) or invalid response
- All relays serve the same deterministic BLS signature for a given round
- Validates round number matches declared value
- Returns: randomness (hex), signature (hex), full response text
- HTTP timeouts: 5s connect, 10s receive
- Validates response structure, rejects malformed

### WeatherClient

- Fetches from Met Office Land Observations API
- Station: Middle Wallop (station ID looked up from API)
- Accepts a `target_time` parameter (the draw's declared `weather_time`)
- Finds the pressure reading closest to (but not after) `target_time`, within a 1-hour window
- Rejects observations more than 1 hour before `target_time` to prevent drift across retries
- Normalizes using `Decimal` with `:half_up` rounding to integer string
- Returns: normalized value, raw response text
- API key from `MET_OFFICE_API_KEY` env var
- Same HTTP timeouts as DrandClient
- Validates response structure, rejects missing reading

### Normalization Test Vectors

| Raw pressure | Normalized |
|-------------|------------|
| 1013.0 | "1013" |
| 1013.4 | "1013" |
| 1013.5 | "1014" |
| 1013.9 | "1014" |
| 998.0 | "998" |
| 1050.25 | "1050" |
| 1050.75 | "1051" |

## Lock Time Declarations

When a draw is created without a caller-provided seed:

1. Query current drand round
2. Compute declared round = current + buffer (30+ seconds worth of rounds)
3. Validate declared round has not yet been published
4. Set `weather_time` to next whole hour after current time (this is the scheduled fetch time; the actual observation used will be the latest available at fetch time, recorded as `weather_observation_time`)
5. Set `weather_station` to Middle Wallop identifier
6. Store `drand_chain` (quicknet chain hash)
7. Transition to `awaiting_entropy`
8. Schedule Oban job for just after `weather_time`

## EntropyWorker (Oban Job)

**Queue:** `:entropy` (dedicated)

**Unique constraint:** `[period: :infinity, keys: [:draw_id]]` — one job per draw

**Two-phase retry:**

Phase 1 (attempts 1-5): Try both drand and weather. On transient failure, retry via Oban.

Phase 2 (attempts 6-10): If drand succeeds but weather has failed for 5+ attempts, fall back to drand-only seed computation via `execute_drand_only` action. The `weather_fallback_reason` is stored in the immutable proof record.

**Flow:**
1. Load draw
2. If `awaiting_entropy`: transition to `pending_entropy` (atomic, WHERE status = 'awaiting_entropy')
3. Fetch drand (with relay failover) and weather in parallel via `Task.async`/`Task.await`
4. Broadcast `{:entropy_status, ...}` for proof page live feedback
5. If permanent error (401, 403, invalid response): fail the draw immediately
6. If both available: execute with both entropy sources via `execute_with_entropy`
7. If drand OK but weather failed and attempt >= 5: execute drand-only via `execute_drand_only`
8. If attempt == max_attempts and still failing: fail the draw
9. Otherwise: return `{:error, _}` for Oban retry
10. Enqueue webhook job if `callback_url` is set

**Error classification:**
- Transient (retry): drand 404 (round not yet available), 5xx, transport errors, timeouts
- Permanent (fail immediately): 401, 403, invalid API response structure

**Backoff:** Flat curve via `backoff/1` callback: 15s, 30s, 45s, 60s, 90s for attempts 1-5, then 120s. Total window ~14 minutes across 10 attempts.

## Webhook Delivery

**Queue:** `:webhooks` (separate from entropy — slow callbacks can't block entropy processing)

**Payload (minimal):**
```json
{
  "draw_id": "uuid",
  "status": "completed"
}
```
Or:
```json
{
  "draw_id": "uuid",
  "status": "failed",
  "failure_reason": "Weather observation unavailable after 24 hours"
}
```

Caller fetches full results via `GET /api/v1/draws/:id`.

**Signature:** `X-Wallop-Signature: t=<unix_timestamp>,v1=<hmac>`

Where `hmac = HMAC-SHA256(webhook_secret, "#{timestamp}.#{payload}")`. Receivers should reject signatures older than 5 minutes.

**Delivery:** Best-effort for MVP. Fire once, log failures. No retry queue.

**SSRF protection on callback_url:**
- Must be HTTPS
- Reject private IPs (127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, ::1)
- Reject localhost
- Validated at draw creation time

## Updated Immutability Trigger

```sql
CREATE OR REPLACE FUNCTION prevent_draw_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- Terminal states: block ALL changes
  IF OLD.status IN ('completed', 'failed') THEN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'Cannot delete a % draw', OLD.status;
    END IF;
    RAISE EXCEPTION 'Cannot modify a % draw', OLD.status;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- Enforce valid state transitions
    IF OLD.status = 'locked' AND NEW.status NOT IN ('locked', 'awaiting_entropy', 'completed') THEN
      RAISE EXCEPTION 'Invalid state transition from locked to %', NEW.status;
    END IF;
    IF OLD.status = 'awaiting_entropy' AND NEW.status NOT IN ('awaiting_entropy', 'pending_entropy') THEN
      RAISE EXCEPTION 'Invalid state transition from awaiting_entropy to %', NEW.status;
    END IF;
    IF OLD.status = 'pending_entropy' AND NEW.status NOT IN ('pending_entropy', 'completed', 'failed') THEN
      RAISE EXCEPTION 'Invalid state transition from pending_entropy to %', NEW.status;
    END IF;

    -- Block caller-seed execute if entropy sources are declared
    IF OLD.drand_round IS NOT NULL AND NEW.seed_source = 'caller' THEN
      RAISE EXCEPTION 'Cannot use caller-provided seed when entropy sources are declared';
    END IF;

    -- Protect committed fields (all non-terminal states)
    IF NEW.entries IS DISTINCT FROM OLD.entries
       OR NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
       OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical
       OR NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN
      RAISE EXCEPTION 'Cannot modify committed entry fields';
    END IF;

    -- Protect declared entropy fields (awaiting_entropy and pending_entropy)
    IF OLD.status IN ('awaiting_entropy', 'pending_entropy') THEN
      IF NEW.drand_round IS DISTINCT FROM OLD.drand_round
         OR NEW.drand_chain IS DISTINCT FROM OLD.drand_chain
         OR NEW.weather_station IS DISTINCT FROM OLD.weather_station
         OR NEW.weather_time IS DISTINCT FROM OLD.weather_time THEN
        RAISE EXCEPTION 'Cannot modify declared entropy fields';
      END IF;
    END IF;
  END IF;

  -- Allow DELETE on non-terminal states (cancellation)
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

## Dependencies to Add

- `wallop_core`: `oban` (~> 2.18), `req` (~> 0.5), `cloak_ecto` (~> 1.3), `decimal` (already via ecto)
- Config: Oban queues (`:entropy`, `:webhooks`), Cloak vault

## Project Structure (New Files)

| File | Responsibility |
|------|---------------|
| `apps/wallop_core/lib/wallop_core/entropy/drand_client.ex` | drand beacon HTTP client |
| `apps/wallop_core/lib/wallop_core/entropy/weather_client.ex` | Met Office HTTP client |
| `apps/wallop_core/lib/wallop_core/entropy/entropy_worker.ex` | Oban job: fetch entropy, execute draw |
| `apps/wallop_core/lib/wallop_core/entropy/webhook_worker.ex` | Oban job: deliver webhook |
| `apps/wallop_core/lib/wallop_core/entropy/callback_url.ex` | URL validation (HTTPS, no private IPs) |
| `apps/wallop_core/lib/wallop_core/vault.ex` | Cloak vault for webhook_secret encryption |
| Migration: update draws table | Add new columns |
| Migration: update api_keys table | Add webhook_secret column |
| Migration: update immutability trigger | New states and field protections |

## Testing Strategy

| Layer | What to test |
|-------|-------------|
| DrandClient | Parse valid response, validate chain hash, validate round, reject malformed, handle timeout |
| WeatherClient | Parse valid response, normalize pressure (Decimal half-up), test vectors, validate station/time, reject missing, handle timeout |
| EntropyWorker | Happy path → completed + webhook, partial availability → retry, failure timeout → failed + webhook, idempotency, atomic transitions, entry hash re-verification |
| Webhook delivery | Correct HMAC signature, minimal payload, separate queue, SSRF validation |
| State machine | All valid transitions, invalid transitions blocked, caller-seed blocked when entropy declared, pending_entropy only by internal action |
| DB trigger | Updated trigger tests for all new states and protections |
| Integration | Create draw → awaiting_entropy → mock entropy → completed with correct results |

HTTP clients tested with mocked responses. Oban jobs tested with `Oban.Testing`.

## Deferred (not in sub-project 2)

- BLS signature verification on drand responses
- Drand relay failover (multiple endpoints)
- Webhook retry queue with exponential backoff
- Per-API-key configurable failure timeout
