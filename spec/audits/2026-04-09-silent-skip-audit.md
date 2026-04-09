# Silent Skip Path Audit

> Audit date: 2026-04-09. Covers wallop_core 0.14.0.
>
> Every code path where a security-critical operation silently succeeds
> instead of failing when a precondition is missing.

## Pattern

The bug class: a change module checks a precondition, finds it missing,
and returns `{:ok, draw}` or `changeset` instead of `{:error, reason}`.
The draw completes "successfully" with degraded or absent cryptographic
attestation.

This was the root cause of the operator-less draw bug (draws completing
with zero receipts). The fix (0.14.0) closed the operator path. This
audit checks for remaining instances of the same pattern.

## Findings and fixes

### F-1: operator_slug fallback to "unknown" — FIXED

`SignAndStoreExecutionReceipt.load_operator_slug/1` returned `"unknown"`
if the operator lookup failed. Execution receipts were signed with
corrupted metadata. Now raises on failure (`load_operator_slug!/1`).

### F-2: app_version fallback to "unknown" — FIXED

Both `SignAndStoreReceipt` and `SignAndStoreExecutionReceipt` had
`app_version/1` returning `"unknown"` if `Application.spec` returned
nil. Receipts were signed with unverifiable version info. Now raises
(`app_version!/1`).

### F-3: increment_draw_count swallowed errors — FIXED

`IncrementApiKeyDrawCount` discarded the `Ash.update` result, always
returning `:ok`. Quota tracking failures were invisible. Now propagates
errors.

### F-4: validate_entries nil passthrough — ACCEPTABLE

`ValidateEntries` returns `changeset` unchanged when entries are nil.
This is acceptable because entries are required via the `:add_entries`
action before `:lock` can proceed. The nil path exists for the initial
`:create` where entries haven't been added yet.

### F-5: PubSub broadcast errors — ACCEPTABLE

`BroadcastUpdate` and `DeclareEntropy` discard PubSub/Oban results.
These are observability and scheduling operations, not cryptographic.
A failed broadcast doesn't affect the proof chain. A failed Oban
insert would delay execution but the draw state is already committed.

### F-6: DrawPubSub operator skip — MOOT

Conditional broadcast skip when `operator_id` is nil. Since 0.14.0
requires operators on all draws, this path is unreachable.

## Rule going forward

No silent skips in receipt signing, sequence assignment, or any code
path that produces or validates cryptographic artefacts. If a
precondition is missing, fail hard. Use `!` suffix functions
(`app_version!`, `load_operator_slug!`) to signal this intent.
