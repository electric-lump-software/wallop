# Race Condition Audit

> Audit date: 2026-04-09. Covers wallop_core 0.13.2.
>
> Every state-transitioning code path audited for its locking strategy
> and concurrent execution safety.

## Locking strategy

All Draw update actions use `filter(expr(status == :expected))` which
compiles to `UPDATE draws SET ... WHERE id = $1 AND status = $2`. If
the status has changed between the Ash query and the UPDATE, the WHERE
returns 0 rows and the update is a no-op.

This is **optimistic concurrency control** — no explicit row locks, but
the atomic WHERE clause prevents corrupt state. The trade-off: a lost
race is a silent no-op, not an error.

The one exception is the **entries trigger**, which uses
`SELECT ... FOR UPDATE` to serialize entry mutations with draw status
changes. This is pessimistic locking and is correct.

## Oban uniqueness

The EntropyWorker uses `unique: [period: :infinity, keys: [:draw_id]]`.
Only one job per draw_id can exist in the queue. This prevents the most
dangerous race: two entropy workers executing the same draw concurrently.

## Race scenarios

### 1. Two entropy worker retries on the same draw

**Risk:** LOW (prevented by Oban uniqueness)

If the first attempt fails and retries, Oban's uniqueness constraint
prevents a second job from being enqueued. The retry uses the same job
row.

### 2. Entropy worker vs expiry worker

**Risk:** LOW (different state filters)

ExpiryWorker targets `status == :open`. EntropyWorker targets
`awaiting_entropy` / `pending_entropy`. They cannot race on the same
draw because they target different states. A draw must be locked (leaving
`:open`) before the entropy worker touches it.

### 3. Concurrent lock attempts (two API clients)

**Risk:** LOW (atomic WHERE clause)

Both execute `UPDATE draws SET status = :awaiting_entropy WHERE status = :open`.
One succeeds, the other gets 0 affected rows. No data corruption.
Ash returns an error to the second caller.

### 4. Entry insertion during lock transition

**Risk:** MITIGATED (FOR UPDATE in entries trigger)

The entries trigger acquires a row lock on the parent draw via
`SELECT status FROM draws WHERE id = ... FOR UPDATE`. This serializes
entry mutations with the lock transition. If the draw has left `:open`,
the entry insert is rejected.

### 5. Concurrent execute_with_entropy calls

**Risk:** LOW (Oban uniqueness + atomic WHERE)

Only the EntropyWorker calls this action. Oban uniqueness prevents
duplicate jobs. Even if two somehow ran, the WHERE clause
(`status == :pending_entropy`) means only one can succeed.

### 6. mark_failed during execution

**Risk:** LOW (atomic WHERE clause)

`mark_failed` filters on `status in [:pending_entropy, :awaiting_entropy]`.
`execute_with_entropy` filters on `status == :pending_entropy`. If
execution completes first (status → completed), `mark_failed` finds 0
rows. If `mark_failed` completes first (status → failed), execution
finds 0 rows. No interleaving — exactly one wins.

## Findings

**No critical race conditions found.** The optimistic concurrency
strategy (atomic WHERE clauses) combined with Oban job uniqueness
provides sufficient protection for the current architecture.

**F-1 (LOW): Silent failure on lost races.** When a WHERE clause
returns 0 rows, Ash returns an error tuple, not a success. Callers
(EntropyWorker, API controllers) handle this correctly — the worker
retries, the API returns an error response. No silent data loss.

**F-2 (LOW): No explicit row locks on draw state transitions.** The
entries trigger is the only place that uses FOR UPDATE. Draw state
transitions rely entirely on the atomic WHERE clause. This is
acceptable for the current single-node architecture. If wallop ever
runs multiple application nodes with shared Oban queues, the Oban
uniqueness constraint (database-backed) continues to protect against
duplicate entropy worker execution.

## F-3: LockDraw TOCTOU — fixed

The `LockDraw` change module computed `entry_hash` from a plain
SELECT on the entries table before the draw UPDATE acquired a row
lock. An entry INSERT could sneak in between the hash computation
and the lock transition, producing a stale hash. Not exploitable
(execution catches the hash mismatch), but the draw becomes stuck.

**Fix:** `LockDraw` now issues `SELECT id FROM draws WHERE id = $1
FOR UPDATE` before reading entries. This acquires the row lock first,
serializing with the entries trigger's own FOR UPDATE.

## DB trigger as backstop

Even if a race somehow produced an invalid state transition, the
`prevent_draw_mutation()` trigger independently validates:
- Terminal states (completed/failed/expired) block all mutations
- Valid state transitions only (no backward transitions)
- Committed fields frozen after lock

This is defence in depth — the trigger catches anything the application
layer misses.
