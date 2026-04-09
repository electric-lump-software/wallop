# Action Reachability Matrix

> Audit date: 2026-04-09. Covers wallop_core 0.13.2.
>
> Every Ash action on Draw, SandboxDraw, and Entry, with the state
> filter that gates it, the policy that controls access, and what it
> writes. If an action can fire from a state its docstring doesn't
> mention, that's a bug.

## Draw

| Action | Type | State filter | Policy | Writes | Change modules |
|--------|------|-------------|--------|--------|----------------|
| `create` | create | — | actor_present | status=open, api_key_id, name, winner_count, metadata, callback_url | AssignOperatorSequence, IncrementApiKeyDrawCount, ValidateCallbackUrl, RecordStageTimestamp(opened_at), BroadcastUpdate |
| `add_entries` | update | open | owner (api_key_id == actor) | entries (via change), entry_count, entry_hash | ValidateEntries, AddEntries |
| `remove_entry` | update | open | owner | entries (via change), entry_count, entry_hash | RemoveEntry |
| `update_name` | update | open | owner | name | BroadcastUpdate |
| `lock` | update | open | owner | entry_hash, entry_canonical, status→awaiting_entropy, drand_*/weather_* declarations, operator receipt | LockDraw, DeclareEntropy, RecordStageTimestamp(locked_at, entropy_declared_at), SignAndStoreReceipt |
| `execute` | update | locked | owner | seed (caller), seed_source=caller, results, status→completed, executed_at | ExecuteDraw (validates NoEntropyDeclared) |
| `transition_to_pending` | update | awaiting_entropy | **internal only** | status→pending_entropy | — |
| `execute_with_entropy` | update | pending_entropy | **internal only** | drand_randomness, drand_signature, drand_response, weather_value, weather_raw, weather_observation_time, seed, results, status→completed | ExecuteWithEntropy, SignAndStoreExecutionReceipt, BroadcastUpdate |
| `execute_drand_only` | update | pending_entropy | **internal only** | drand_randomness, drand_signature, drand_response, weather_fallback_reason, seed, results, status→completed | ExecuteDrandOnly, RecordStageTimestamp(executed_at), SignAndStoreExecutionReceipt, BroadcastUpdate |
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

- `transition_to_pending` (EntropyWorker)
- `execute_with_entropy` (EntropyWorker)
- `execute_drand_only` (EntropyWorker)
- `expire` (ExpiryWorker)
- `mark_failed` (EntropyWorker)

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

**No findings.** Every action's state filter matches its documented
intent. No action is reachable from a state it shouldn't be. The
DB triggers provide independent enforcement of the same constraints.

The `locked` state exists briefly between `lock` completing and
`DeclareEntropy` running (both in the same transaction). The `:execute`
action filters on `locked`, which is the caller-seed path (no entropy
declaration). This is correct — caller-seed draws never enter
`awaiting_entropy`.
