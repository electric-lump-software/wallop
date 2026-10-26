# Action Reachability Matrix

> Audit date: 2026-04-09. Covers wallop_core 0.13.2.
>
> Superseded in part by the retirement of forecast draws (0.29.0): `execute_with_entropy` and `execute_drand_only` no longer exist; draws execute through `execute_v6`.
>
> Every Ash action on Draw, SandboxDraw, and Entry, with the state
> filter that gates it, the policy that controls access, and what it
> writes. If an action can fire from a state its docstring doesn't
> mention, that's a bug.

## Draw

| Action | Type | State filter | Policy | Writes | Change modules |
|--------|------|-------------|--------|--------|----------------|
| `create` | create | — | actor_present | status=open, api_key_id, name, winner_count, metadata, callback_url | AssignOperatorSequence, IncrementApiKeyDrawCount, ValidateCallbackUrl, RecordStageTimestamp(opened_at), BroadcastUpdate |
| `add_entries` | update | open | owner (api_key_id == actor) | entries (via change), entry_count, add_entries_idempotency rows (insert-or-replay; ADR-0012) | ValidateEntries, HashAndClearClientRef, CheckIdempotency, AddEntries |
| `remove_entry` | update | open | owner | entries (via change), entry_count, entry_hash | RemoveEntry |
| `update_name` | update | open | owner | name | BroadcastUpdate |
| `update_winner_count` | update | open | owner | winner_count | BroadcastUpdate |
| `lock` | update | open | owner | entry_hash, entry_canonical, status→awaiting_entropy, drand_*/weather_* declarations (`weather_time` operator-supplied if argument provided, else jittered default; `drand_round` derived from `weather_time`), operator receipt; same-tx DELETE of add_entries_idempotency rows for this draw (ADR-0012) | LockDraw, DeclareEntropy (validates supplied weather_time via Validations.WeatherTime), RecordStageTimestamp(locked_at, entropy_declared_at), SignAndStoreReceipt |
| `execute` | update | locked | owner | seed (caller), seed_source=caller, results, status→completed, executed_at | ExecuteDraw (validates NoEntropyDeclared) |
| `transition_to_pending` | update | awaiting_entropy | **internal only** | status→pending_entropy | — |
| `execute_with_entropy` | update | pending_entropy and lock_schema_version nil | **internal only** | drand_randomness, drand_signature, drand_response, weather_value, weather_raw, weather_observation_time, seed, results, status→completed | ExecuteWithEntropy, SignAndStoreExecutionReceipt, BroadcastUpdate |
| `execute_drand_only` | update | pending_entropy and lock_schema_version nil | **internal only** | drand_randomness, drand_signature, drand_response, weather_fallback_reason, seed, results, status→completed | ExecuteDrandOnly, RecordStageTimestamp(executed_at), SignAndStoreExecutionReceipt, BroadcastUpdate |
| `execute_v6` | update | pending_entropy, lock_schema_version 6 | **internal only** (ObservationDrawWorker, EntropyWorker for v6 draws); `forbid_if(always())` | drand_randomness, drand_signature, drand_response; weather_value, weather_raw, weather_observation_time from the stored reading, or weather_fallback_reason by rule; seed, results, status→completed, executed_at | ExecuteV6, RecordStageTimestamp(executed_at), SignAndStoreExecutionReceipt(version 6), EnqueueWebhook, BroadcastUpdate |
| `expire` | update | open | **internal only** | status→expired | BroadcastUpdate |
| `mark_failed` | update | pending_entropy, awaiting_entropy | **internal only** | status→failed, failed_at, failure_reason | BroadcastUpdate |
| `read` | read | — | owner (api_key_id == actor) | — | — |

### State machine

```
open ──→ awaiting_entropy ──→ pending_entropy ──→ completed
  │              │                    │
  │              │                    └──→ failed
  │              └──→ failed
  │              └──→ completed (caller-seed via :execute from :locked)
  └──→ expired
```

### Internal-only actions

These have `forbid_if(always())` policies — only reachable via
`authorize?: false` (Oban workers, change modules):

- `transition_to_pending` (EntropyWorker, V6Execution)
- `execute_with_entropy` (EntropyWorker)
- `execute_drand_only` (EntropyWorker)
- `execute_v6` (ObservationDrawWorker, and EntropyWorker for v6 draws, both through V6Execution)
- `expire` (ExpiryWorker)
- `mark_failed` (EntropyWorker; V6Execution only before drand is fetched)

### DB trigger enforcement

The draws immutability trigger independently enforces:
- Terminal states (completed/failed/expired): all mutations blocked
- winner_count: immutable after creation
- entry_hash/entry_canonical/entries: immutable after open
- drand_round/drand_chain/weather_station/weather_time: immutable in awaiting_entropy/pending_entropy
- seed_source=caller blocked when drand_round is set
- State transitions validated (no backward transitions)

## SandboxDraw

| Action | Type | State filter | Policy | Writes | Change modules |
|--------|------|-------------|--------|--------|----------------|
| `create` | create | — | actor_present | name, winner_count, entries, seed (hardcoded), results, executed_at | SetActorFields, ValidateEntries, ExecuteWithSandboxSeed, EmitCreateTelemetry |
| `read` | read | — | owner (api_key_id == actor) | — | — |

SandboxDraw is create-and-execute in one transaction. No state machine,
no receipts, no transparency log. Structurally incapable of being
confused with a real draw.

## Entry

| Action | Type | State filter | Policy | Writes | Change modules |
|--------|------|-------------|--------|--------|----------------|
| `create` | create | — | **internal only** | draw_id, entry_id, weight | — |
| `destroy` | destroy | — | **internal only** | — | — |
| `read` | read | — | owner (draw.api_key_id == actor) | — | — |

Entry mutations are gated by the entries immutability trigger at the
DB level: INSERT/UPDATE/DELETE blocked when draw status != open.

## Findings

**F-1: `:execute` action is valid but currently unreachable.**

The `:execute` action filters on `status == :locked`. No code path
currently produces `:locked` state — the `lock` action atomically
transitions `open → awaiting_entropy` because `LockDraw` and
`DeclareEntropy` run in the same Ash changeset (single SQL UPDATE).

This is intentional — the caller-seed path ("lock and wait") is a
future feature. To enable it, the `lock` action needs to be split
so draws can pause in `:locked` before entropy declaration. Filed
as a separate card.

The `:execute` action, `NoEntropyDeclared` validation, and `:locked`
status enum value are retained as forward-looking infrastructure.

**No security findings.** Every reachable action's state filter matches
its documented intent. The DB triggers independently enforce the same
constraints.
