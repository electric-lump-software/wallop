# Wallop API + Database Design

Sub-project 1 of 3. Implements the core API service for creating and executing provably fair draws.

## Overview

A REST API (JSON:API format) backed by PostgreSQL for creating draws, executing them with a caller-provided seed, and retrieving results. Ash Framework for the resource layer, Phoenix for HTTP.

**Sub-projects:**
1. **API + Database** (this spec) — Draw resource, API keys, state machine, immutability
2. **Entropy layer** (future) — drand client, Met Office client, automatic seed computation
3. **Proof pages** (future) — public verification pages

## Data Model

### Draw

| Field | Type | Notes |
|-------|------|-------|
| `id` | `:uuid` | Primary key |
| `api_key_id` | `:uuid` | FK to ApiKey (who created this draw) |
| `status` | `:atom` | `:locked`, `:completed` |
| `entries` | `:map` | JSONB — entry list as submitted |
| `entry_hash` | `:string` | SHA256 of canonical entries (computed on create) |
| `entry_canonical` | `:string` | JCS-serialized entries (for proof record) |
| `winner_count` | `:integer` | How many winners to select |
| `seed` | `:string` | Hex-encoded 32-byte seed (set on execute) |
| `seed_source` | `:atom` | Constrained enum: `:caller` (sub-project 1) or `:entropy` (sub-project 2) |
| `seed_json` | `:string` | JCS string used to compute seed (null for sub-project 1) |
| `results` | `:map` | JSONB — ordered winner list (set on execute) |
| `metadata` | `:map` | JSONB — caller-provided context (optional) |
| `executed_at` | `:utc_datetime_usec` | When the draw was executed |
| `inserted_at` | `:utc_datetime_usec` | |
| `updated_at` | `:utc_datetime_usec` | |

**Indexes:**
- `draws.api_key_id` — for list queries scoped by API key
- `draws.status` — for finding locked draws

**Note on `winner_count`:** May exceed the number of unique entries. The algorithm handles this gracefully by returning all distinct entries. This is by design, not an error.

**Note on forward compatibility:** Sub-project 2 will add `:pending_entropy` status between `:locked` and `:completed`. The trigger and policies are written to be forward-compatible — they operate on `:completed` and `:locked` specifically, not on an exhaustive enum.

### ApiKey

| Field | Type | Notes |
|-------|------|-------|
| `id` | `:uuid` | Primary key |
| `name` | `:string` | Human label |
| `key_hash` | `:string` | bcrypt hash of the raw key |
| `key_prefix` | `:string` | First 8 chars of random portion (after `wallop_`) |
| `active` | `:boolean` | Default true |
| `deactivated_at` | `:utc_datetime_usec` | Null until deactivated |
| `inserted_at` | `:utc_datetime_usec` | |
| `updated_at` | `:utc_datetime_usec` | |

**Indexes:**
- Unique index on `api_keys.key_prefix` — for auth lookup

Key format: `wallop_<random>` where `<random>` is 32 bytes from `:crypto.strong_rand_bytes/1`, base62-encoded. Raw key returned once on creation, never stored. Prefix is first 8 chars of the random portion (62^8 = ~218 trillion possible prefixes).

## Draw Actions & State Machine

### Actions

| Action | Type | Description |
|--------|------|-------------|
| `create` | `:create` | Accepts entries, winner_count, optional metadata. Computes entry_hash and entry_canonical. Sets status to `:locked`. |
| `execute` | `:update` | Accepts seed (hex string). Runs algorithm, stores results. Transitions to `:completed`. |
| `read` | `:read` | Get a draw by ID. |
| `list` | `:read` | List draws for the authenticated API key. Paginated. |

### State machine

- Initial state: `:locked`
- Only transition: `:locked` → `:completed` (via execute action)

### Policies

- `create` — requires authenticated API key
- `execute` — requires authenticated API key, must be the key that created the draw, draw must be `:locked`
- `read` / `list` — requires authenticated API key, scoped to own draws (filter by `api_key_id`)

### Validations

**On create:**
- `entries` — non-empty list, max 10,000 entries, each has `id` (string) and `weight` (positive integer, max 1,000), no duplicate IDs, max total weight 100,000
- `winner_count` — positive integer

**On execute:**
- `seed` — 64-character hex string (32 bytes)
- Draw must be in `:locked` status

### Execute flow

1. Begin transaction, `SELECT ... FOR UPDATE` on the draw row
2. Assert status is `:locked`
3. Recompute entry_hash from stored entries, assert it matches stored hash
4. Decode hex seed to 32 bytes
5. Convert entries from JSONB string-keyed maps (`%{"id" => ..., "weight" => ...}`) to atom-keyed maps (`%{id: ..., weight: ...}`) as required by `FairPick.draw/3`
6. Call `FairPick.draw(converted_entries, seed_bytes, draw.winner_count)`
7. Store results, seed, seed_source (`:caller`), executed_at
8. Transition status to `:completed`

## ApiKey Management

### Actions (internal only, no API exposure)

| Action | Type | Description |
|--------|------|-------------|
| `create` | `:create` | Generates key, bcrypt hashes it, stores hash + prefix. Returns raw key. |
| `read` | `:read` | Look up by ID. |
| `deactivate` | `:update` | Sets active to false, records deactivated_at. |

### Mix tasks

- `mix wallop.gen.api_key "Name"` — creates key, prints it once
- `mix wallop.list.api_keys` — lists keys (prefix, name, active, created_at)
- `mix wallop.deactivate.api_key <prefix>` — deactivates a key

Mix tasks live in `apps/wallop_core/lib/mix/tasks/`.

## Authentication

Bearer token via `Authorization: Bearer wallop_<key>` header.

### Auth plug flow

1. Read `Authorization: Bearer <key>` header
2. Check rate limit for source IP — reject with 429 if exceeded
3. Extract prefix (first 8 chars after `wallop_`)
4. Look up ApiKey by prefix where `active: true`
5. If not found, run `Bcrypt.no_user_verify()` (timing safety), return 401
6. If found, bcrypt-verify full key against stored hash
7. If match, assign ApiKey to `conn.assigns.api_key`. If not, return 401

All failure cases return 401 with identical response body. No distinction between missing key, invalid key, or deactivated key.

### Rate limiting

Per-IP rate limit on authentication failures. ETS-based counter (single-node MVP):
- 10 failures per minute per IP
- Counter resets after 60-second window expires
- Returns 429 when exceeded
- Multi-node rate limiting is out of scope for MVP

Implemented at the plug level before bcrypt verify to prevent CPU exhaustion.

## API Endpoints (JSON:API)

Base path: `/api/v1`

All requests and responses use [JSON:API](https://jsonapi.org/) format.

### POST /api/v1/draws

Create and lock a draw.

**Request:**
```json
{
  "data": {
    "type": "draw",
    "attributes": {
      "entries": [
        {"id": "entry-1", "weight": 1},
        {"id": "entry-2", "weight": 3}
      ],
      "winner_count": 1,
      "metadata": {"source": "your-app", "external_id": "abc-123"}
    }
  }
}
```

**Response (201):** Draw resource with fields: `id`, `status`, `entry_hash`, `winner_count`, `entry_count` (computed), `total_weight` (computed), `inserted_at`. Entries are not included in the response (they could be large). The `entry_hash` serves as the commitment.

### POST /api/v1/draws/:id/execute

Execute a locked draw with a caller-provided seed.

**Request:**
```json
{
  "data": {
    "type": "draw",
    "attributes": {
      "seed": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    }
  }
}
```

**Response (200):** Draw resource with fields: `id`, `status`, `results`, `seed`, `seed_source`, `entry_hash`, `executed_at`.

### GET /api/v1/draws/:id

Retrieve a draw by ID. Returns all fields. If locked, results/seed/executed_at are null.

### GET /api/v1/draws

List draws for the authenticated API key. Paginated via JSON:API pagination parameters.

### Error responses

- 401 — unauthorized
- 404 — draw not found (or belongs to another key)
- 409 — conflict (executing an already-completed draw)
- 422 — validation error
- 429 — rate limited

## Immutability

### Two-layer enforcement

**Layer 1: Ash policies** — Forbid update/destroy actions when status is `:completed`.

**Layer 2: PostgreSQL trigger** — Defense-in-depth for anything bypassing Ash.

```sql
CREATE OR REPLACE FUNCTION prevent_draw_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- Completed draws: block ALL changes (update and delete)
  IF OLD.status = 'completed' THEN
    RAISE EXCEPTION 'Cannot modify or delete a completed draw';
  END IF;

  -- Locked draws: protect committed fields (entries, hash, winner_count)
  -- DELETE on locked draws is permitted (draw cancellation before execution)
  IF TG_OP = 'UPDATE' AND OLD.status = 'locked' THEN
    IF NEW.entries IS DISTINCT FROM OLD.entries
       OR NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
       OR NEW.entry_canonical IS DISTINCT FROM OLD.entry_canonical
       OR NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN
      RAISE EXCEPTION 'Cannot modify committed fields on a locked draw';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_draw_immutability
  BEFORE UPDATE OR DELETE ON draws
  FOR EACH ROW
  EXECUTE FUNCTION prevent_draw_mutation();
```

**Note:** DELETE on locked draws is intentionally permitted to allow cancellation of un-executed draws.

### Deployment note

In production, the application should connect as a restricted database role (`wallop_app`) that cannot `TRUNCATE` tables or `DISABLE TRIGGER`. Only the migration role should own the tables. This prevents the trigger from being bypassed.

## Project Structure

### Dependencies to add

These are additions to the current mix.exs files (which already have `fair_pick`, `jcs`, `jason`, `credo`):

- `wallop_core`: `ash`, `ash_postgres`, `bcrypt_elixir`
- `wallop_web`: `phoenix`, `bandit`, `ash_json_api`

### Key files

| File | Responsibility |
|------|---------------|
| `apps/wallop_core/lib/wallop_core/domain.ex` | Ash domain (registers resources) |
| `apps/wallop_core/lib/wallop_core/repo.ex` | Ecto repo |
| `apps/wallop_core/lib/wallop_core/resources/draw.ex` | Draw Ash resource |
| `apps/wallop_core/lib/wallop_core/resources/api_key.ex` | ApiKey Ash resource |
| `apps/wallop_core/lib/mix/tasks/wallop.gen.api_key.ex` | Key creation task |
| `apps/wallop_core/lib/mix/tasks/wallop.list.api_keys.ex` | Key listing task |
| `apps/wallop_core/lib/mix/tasks/wallop.deactivate.api_key.ex` | Key deactivation task |
| `apps/wallop_web/lib/wallop_web/endpoint.ex` | Phoenix endpoint |
| `apps/wallop_web/lib/wallop_web/router.ex` | Phoenix router + AshJsonApi |
| `apps/wallop_web/lib/wallop_web/plugs/api_key_auth.ex` | Auth plug |
| `apps/wallop_web/lib/wallop_web/plugs/rate_limit.ex` | ETS-based rate limiting |

### Migrations

1. `create_api_keys` — ApiKey table with unique index on key_prefix
2. `create_draws` — Draw table with FK to api_keys, indexes on api_key_id and status
3. `add_immutability_trigger` — PostgreSQL trigger function

## Testing Strategy

| Layer | What to test |
|-------|-------------|
| Draw resource | Create with valid/invalid entries, bounds validation (max entries, max weight, max total weight), execute with valid/invalid seed, state transitions, immutability (can't execute twice), policy enforcement (can't execute another key's draw) |
| Protocol integration | Create draw → execute with spec vector P-3 inputs → assert results match frozen spec values end-to-end |
| Auth plug | Valid key, invalid key, missing header, deactivated key, timing safety (dummy bcrypt on miss), rate limiting |
| DB trigger | Raw SQL UPDATE on completed draw raises, DELETE on completed draw raises, UPDATE committed fields on locked draw raises, DELETE on locked draw succeeds |
| Mix tasks | Key creation stores bcrypt hash, listing shows prefix, deactivation sets active=false and deactivated_at |
| API endpoints | Full HTTP round-trips through JSON:API endpoints (create, execute, read, list) |

## Future (not this sub-project)

- Sub-project 2: Entropy layer (drand client, Met Office client, `pending_entropy` status, automatic seed computation)
- Sub-project 3: Proof pages (public verification, re-verify button)
- Deployment: Dockerfile + railway.toml (same pattern as existing projects)
