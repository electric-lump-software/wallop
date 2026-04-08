# Wallop Threat Model

> **Status:** v1, 2026-04-08. Pre-launch. Living document — update as the
> system changes. The protocol-level spec lives at
> [`spec/protocol.md`](protocol.md); this document is about the
> *enforcement* of the claims that spec makes.
>
> **How to use this:** every PR that touches a protocol-critical resource
> should be reviewed against the **invariants** in §2 and the **enforcement
> matrix** in §3. Empty cells in the matrix are findings. Anywhere a future
> change weakens the matrix without updating it is a regression.

## Why this document exists

PAM-670 (sandbox draws on the operator registry) was discovered visually,
not analytically. Once it was investigated, the same shape of bug surfaced
in **seven more places** (PAM-685..691) within an hour of reading the
codebase with a "what invariant does this code uphold?" lens. Every prior
review had been a microscope on a specific PR; nobody had ever looked at
wallop as a *system* and asked "what claims does it make, and what stops
each one being violated?"

Colin's diagnosis: *"Reviews have been local-reasoning exercises, not
adversarial ones. The cheap fix is asking topology questions explicitly.
The real fix is a written threat model."*

This is that document.

---

## 1. Trust assumptions

What wallop trusts, what it does not, and the boundaries of each.

### 1.1 Trusted

| Component | Trusted to | If compromised |
|---|---|---|
| **drand quicknet** ([league of entropy](https://drand.love)) | Produce unpredictable, signed beacon randomness that nobody knew before its round resolved | Every draw whose seed depends on the compromised round becomes potentially predictable. Old draws are unaffected (they used different rounds); future draws can switch chains. |
| **UK Met Office DataHub** (Middle Wallop weather station) | Report a real temperature observation at a specific time | Soft compromise: weather is one of two entropy sources, drand-only fallback exists (after attempt 5). Hard compromise (attacker controls both drand AND Met Office) breaks unpredictability for affected draws. |
| **OTP `:crypto`** (Ed25519, SHA256) | Implement the named primitives correctly | Catastrophic, but outside our threat model — same risk as every Erlang/OTP user. |
| **Postgres** | Atomicity, durability, trigger enforcement, FK integrity | Catastrophic. The immutability triggers and FK constraints are wallop's last line of defence. |
| **Cloak.Vault + VAULT_KEY** | Encrypt operator signing private keys at rest | Operator signing private keys are exposed if both the DB and the VAULT_KEY are compromised simultaneously. |
| **The wallop-the-company team** (Dan, plus future) | Run the infrastructure honestly; not modify the receipt log retroactively | Caught by the transparency log and signed receipts. A retroactive change to a receipt produces a Merkle root that doesn't match the published anchor → detectable by any third-party mirror. |
| **The host OS / cloud provider** (Railway today) | Provide a stable, network-isolated runtime environment | Same as Postgres, plus RCE territory. Out of model. |

### 1.2 Not trusted

| Actor | Assumed capabilities |
|---|---|
| **Operators** | May attempt to rig draws by: choosing entry sets after knowing the seed, repeating draws until they like the result, locking parallel draws with the same entries, swapping entries between lock and execution, lying about which seed was used, denying that a published draw is theirs |
| **Entrants** | May attempt to forge entries on a draw they didn't create, modify their weight, repudiate a winning result, or exfiltrate other entrants' data |
| **Anonymous network attackers** | May attempt to mint api keys, substitute signing keys, pollute the receipt or transparency log, DoS in-flight draws, scrape sensitive data |
| **The network** | Hostile by default. Only TLS-secured channels are trusted. No assumption of confidentiality or integrity at IP/TCP. |
| **Consumers of `wallop_core` as a library** (wallop-app, future self-hosters) | May misconfigure runtime flags, expose internal Ash actions through HTTP, or run with incorrect actor scoping. wallop_core must defend against hostile *consumers*, not just hostile *external clients*. (PAM-670 was discovered because of this exact concern.) |

### 1.3 Edge cases worth stating explicitly

- **drand epoch compromise**: out of model. If the entire drand network is
  compromised, every draw using drand entropy is suspect. The transparency log
  doesn't help — drand was the seed, so the seed was knowable. Mitigation:
  switch chains, accept that pre-compromise draws are now retrospectively
  weakened.
- **Met Office API outage**: handled by the drand-only fallback (after attempt
  5 of the entropy worker). The fallback is a deliberate weakening of the
  unpredictability claim, captured in the receipt as `weather_fallback_reason`.
- **Postgres replication lag**: out of model. Wallop assumes single-writer
  semantics on the primary.
- **Vault key rotation**: not currently implemented. Filed as a future-work
  concern, not a current invariant.
- **Operator key rotation**: implemented (append-only `OperatorSigningKey`
  rows with `valid_from` ordering), see invariant **I-9**.
- **Sandbox draws** (`SandboxDraw` resource): structurally separate from real
  draws (PAM-670). Out of fairness scope by design — see §5.

---

## 2. Claimed invariants

Every promise wallop makes, written down. Each invariant has a **label** and a
**definition**. §3 maps each label to its enforcement layer.

### Protocol commitments

- **I-1: Entry set immutability after lock.** Once a draw transitions out of
  `:open`, the set of entries used for the seed computation cannot change. A
  draw's `entry_hash` at lock time is the cryptographic commitment to "these
  exact entries, in this exact order."

- **I-2: Receipt completeness.** The signed operator receipt commits to every
  field that determines whether a third party will trust the draw. An
  operator must not be able to change any outcome-influencing field after
  signing without invalidating the signature. *(See §6 — this is the
  invariant PAM-670 violated, and PAM-675 is the open audit to confirm it
  holds for every other field.)*

- **I-3: Single-shot execution mode.** A draw's execution path (caller-seed
  vs entropy vs sandbox) is fixed at the moment its entries are locked. A
  locked draw cannot be diverted to a different execution path. Sandbox is
  not an execution path of `Draw` at all — it lives in `SandboxDraw`.

- **I-4: Operator sequence integrity.** Each operator has a strictly
  monotonic, gap-free sequence number for the draws it has locked. Gaps
  represent legitimately discarded slots (the operator created and abandoned
  a draw). No actor other than the legitimate operator (or wallop's
  internal expiry worker) can cause a sequence slot to be consumed.

- **I-5: Receipt log append-only-ness.** The `operator_receipts` table is
  append-only. Once a receipt is inserted (in the same transaction as
  `Draw.lock`), it is never modified or deleted. An external actor cannot
  forge receipts.

- **I-6: Transparency anchor integrity.** Periodic Merkle anchors over the
  receipt log are produced only by the legitimate `AnchorWorker` cron, with
  inputs derived from the actual receipt log. An external actor cannot
  pollute the transparency log with fake anchors.

- **I-7: Seed unpredictability.** For any draw using the entropy path
  (`seed_source: :entropy`), the seed is computed from inputs that nobody
  could have known at the moment of lock. Specifically: drand round
  randomness (from a future round), and a Met Office observation from a
  declared future time.

### Authentication and identity

- **I-8: API key non-forgeability.** An actor cannot mint a valid API key
  for an operator without going through wallop's authenticated bootstrap
  path. The bcrypt hash of a forged key cannot collide with a legitimate
  one.

- **I-9: Operator signing key rotation safety.** Operator signing keys are
  append-only with `valid_from` ordering. Old keys remain in the table
  forever so historical receipts continue to verify. Only the legitimate
  bootstrap path can introduce a new "current" key.

- **I-10: Operator slug immutability.** An operator's `slug` is fixed
  forever from creation. The slug is embedded in every signed receipt JCS
  payload and is the canonical identity that verifiers bind to.

### Data scoping and privacy

- **I-11: Cross-operator draw isolation.** An operator (acting via any of
  its api keys) can read and modify only its own draws. No data leaks
  between operators via Ash relationships, JSON:API, or LiveView.

- **I-12: Verifiable old proofs.** Every published draw remains
  cryptographically verifiable forever. The canonical form of `entry_hash`,
  the receipt payload schema, and the algorithm version used by historical
  draws are all knowable from the published artefacts plus stable
  long-version-pinned dependencies.

---

## 3. Enforcement matrix

For each invariant: what enforces it, at which layer. Layers are ordered
weakest (top) to strongest (bottom):

- **convention** — a developer remembers
- **docs** — a docstring claims it
- **test** — CI fails if violated
- **Ash policy** — authorisation refuses
- **Ash validation** — changeset refuses
- **DB constraint** — Postgres refuses (NOT NULL, FK, UNIQUE)
- **DB trigger** — Postgres refuses with custom logic

**A cell marked ⚠️ is a known gap.** A cell marked 🟡 is "indirect" — the
enforcement holds but only because of a chain of upstream guarantees. A cell
marked ✅ is direct enforcement at that layer.

### Protocol commitments

| Invariant | Convention | Docs | Tests | Ash policy | Ash validation | DB constraint | DB trigger |
|---|---|---|---|---|---|---|---|
| **I-1** Entry set immutability after lock | | ✅ Draw.entry_hash docstring | ✅ resource tests, fair-pick vectors | ✅ `Entry.create / destroy` policies forbid direct write (PAM-690 fix) | ✅ `add_entries / remove_entry` filter `status == :open` | ✅ unique `(draw_id, entry_id)` | ✅ `entries_immutability` BEFORE INSERT/UPDATE/DELETE rejects writes when parent draw status ≠ open |
| **I-2** Receipt completeness | | ✅ Protocol module docstring | 🟡 frozen vector for `entry_hash`; **no frozen vector for the receipt payload bytes** (PAM-654 comment, PAM-675) | n/a | n/a | n/a | n/a |
| **I-3** Single-shot execution mode | | ✅ docstrings on each execute action | ✅ PAM-670 SandboxDraw test suite, plus the trigger row "PAM-670: awaiting_entropy → completed forbidden" | ✅ Draw `execute_with_entropy / execute_drand_only` policies forbid external callers | ✅ action filters: `:execute` requires `:locked`, `:execute_with_entropy` requires `:pending_entropy`, `:execute_drand_only` requires `:pending_entropy` | n/a | ✅ trigger forbids `awaiting_entropy → completed`, plus rejects `seed_source = 'sandbox'` writes on `draws` rows |
| **I-4** Operator sequence integrity | | ✅ Operator docstring | ✅ resource tests | ✅ `Draw.expire` now in internal-only forbid list (PAM-685) | n/a | ✅ unique `(operator_id, sequence)` on `operator_receipts` | ✅ trigger forbids modifying terminal-state draws (so an expired-then-resurrected attack is impossible) |
| **I-5** Receipt log append-only-ness | | ✅ OperatorReceipt docstring | ✅ PAM-687 policy hardening test | ✅ `OperatorReceipt.create` forbidden without `authorize?: false` (PAM-687 fix) | n/a | ✅ unique `draw_id` | ✅ Postgres trigger on `operator_receipts` (per the resource docstring) — *needs re-verification per PAM-677* |
| **I-6** Transparency anchor integrity | | ✅ TransparencyAnchor docstring | ✅ PAM-691 policy hardening test | ✅ `TransparencyAnchor.create` forbidden without `authorize?: false` (PAM-691 fix) | n/a | n/a (intentionally soft — `from_receipt_id`/`to_receipt_id` are FKs but the *content* of an anchor is computed by `AnchorWorker`) | ✅ append-only trigger (per the resource docstring) — *needs re-verification per PAM-677* |
| **I-7** Seed unpredictability | | ✅ fair-pick-protocol.md §2.3 | ✅ frozen seed-derivation vectors in protocol_test.exs | n/a — relies on §1.1 trust assumptions | ✅ `execute_with_entropy` arguments are non-nullable; weather time within 1 hour of declared time | n/a | n/a |

### Authentication and identity

| Invariant | Convention | Docs | Tests | Ash policy | Ash validation | DB constraint | DB trigger |
|---|---|---|---|---|---|---|---|
| **I-8** API key non-forgeability | | ✅ ApiKey docstring | ✅ PAM-689 policy hardening test, `api_key_test.exs` | ✅ `ApiKey.create` forbidden without `authorize?: false` (PAM-689 fix) | ✅ `GenerateKey` change generates random secret, stores bcrypt hash + prefix, never the raw key | ✅ unique `key_prefix` | ⚠️ no DB-level guarantee on bcrypt hash format — relies entirely on the change module |
| **I-9** Operator signing key rotation safety | | ✅ OperatorSigningKey docstring | ✅ PAM-686 policy hardening test, key rotation tests | ✅ `OperatorSigningKey.create` forbidden without `authorize?: false` (PAM-686 fix) | n/a | ✅ unique `(operator_id, key_id)` | ⚠️ no trigger preventing UPDATE / DELETE on signing keys — append-only is enforced only by the absence of an Ash update action |
| **I-10** Operator slug immutability | | ✅ Operator docstring | ✅ operator_test.exs | ✅ `update_name` accept list excludes `slug` | n/a | ✅ unique `slug` | ⚠️ no trigger preventing direct UPDATE of `slug` via SQL |

### Data scoping and privacy

| Invariant | Convention | Docs | Tests | Ash policy | Ash validation | DB constraint | DB trigger |
|---|---|---|---|---|---|---|---|
| **I-11** Cross-operator draw isolation | | ✅ Draw policies docstring | ✅ existing draw resource tests, plus the convention test (PAM-685..691) | ✅ Draw read/update policies all check `api_key_id == ^actor(:id)`; same for Entry, ApiKey | n/a | ✅ FK relationships | n/a — relies on Ash policy enforcement |
| **I-12** Verifiable old proofs | | ✅ CHANGELOG, fair-pick-protocol.md | ⚠️ frozen vectors for fair_pick exist; ⚠️ no frozen vector for receipt payload (PAM-675); ⚠️ no historical draw replay corpus (PAM-654 layer 3) | n/a | n/a | n/a | n/a |

### Findings surfaced by the matrix

Five empty cells / ⚠️ markers stand out. **Each is a finding to fix or
explicitly accept.** The first four already have open cards; the fifth is
new and filed as part of this writeup.

1. **I-2 receipt completeness has no frozen vector at the receipt-payload-bytes
   layer.** Tracked in PAM-675 and the comment on PAM-654. Until both land,
   the only thing protecting receipt completeness is human review.
2. **I-12 verifiable old proofs has no historical replay corpus.** Tracked
   in PAM-654 layer 3. A library upgrade (`fair_pick`, `Jcs`, OTP) could
   silently change canonical-form output and we wouldn't notice until a
   third-party verifier complained.
3. **I-9 operator signing key has no trigger preventing direct UPDATE/DELETE.**
   Append-only-ness is enforced only by the absence of an Ash update action.
   Any direct SQL or future Ash action could break the invariant. Filed as
   PAM-694 (this PR's first new finding).
4. **I-10 operator slug has no trigger preventing direct UPDATE.** Same shape
   as I-9. Slug is so load-bearing (it's in every signed receipt) that
   defence-in-depth is worth the trigger. Filed as PAM-695.
5. **I-8 has no DB-level guarantee on the bcrypt hash format.** Lower
   severity — the hash field is opaque bytes and the only producer is the
   `GenerateKey` change. Filing as a low-priority follow-up: **PAM-696**.

---

## 4. Actor capabilities

What each actor type *can* do. Anywhere an action exists that doesn't
appear in this matrix is a finding.

### 4.1 Anonymous (no authentication)

| Surface | Permitted | Forbidden |
|---|---|---|
| Public proof page (`/proof/:id`) | Read any completed draw's results, entries, entropy chain, signed receipt | Anything else |
| Operator registry (`/operator/:slug`) | Read any operator's full draw history, signed receipts, current public key, transparency anchors | Anything else |
| Transparency log (`/transparency`) | Read all anchors, recompute Merkle roots | Anything else |
| Waitlist signup (`POST /signup` or similar) | Create a `WaitlistSignup` row | Read other signups |
| JSON:API (`/api/v1/draws*`) | Nothing — every JSON:API route requires `actor_present()` | All write operations |
| Direct Ash via wallop_core as a dep | Not applicable — wallop_core is server-side, anonymous network actors can't reach Ash directly |  |

### 4.2 Authenticated entrant

Entrants do not exist as a wallop actor type. Wallop has no concept of an
entrant identity; entrants are represented by opaque entry IDs supplied by
the operator. Anything an entrant wants to do is mediated by the operator's
own application.

### 4.3 Operator with valid API key (active, not deactivated)

| Action | Allowed | Notes |
|---|---|---|
| `Draw.create` | ✅ | Sets `api_key_id` and `operator_sequence` automatically |
| `Draw.add_entries` | ✅ on own draws in `:open` | Validation: PII rejection, weight caps, count caps, unique IDs within batch |
| `Draw.remove_entry` | ✅ on own draws in `:open` | |
| `Draw.update_name` | ✅ on own draws in `:open` | |
| `Draw.lock` | ✅ on own draws in `:open` | Atomically signs the operator receipt |
| `Draw.execute` (caller-seed) | ✅ on own draws in `:locked` | Caller-supplied seed, no entropy declared |
| `Draw.read` | ✅ scoped to `api_key_id == ^actor(:id)` | Cannot read another api_key's draws |
| `Draw.expire` | ❌ (PAM-685 fix) | Internal-only |
| `Draw.execute_with_entropy / execute_drand_only / transition_to_pending / mark_failed` | ❌ | Internal-only |
| `Entry.create / destroy` | ❌ direct (PAM-690 fix) | Must go through `Draw.add_entries / remove_entry` |
| `Entry.read` | ✅ scoped via parent draw's `api_key_id` | |
| `Operator.read` | ✅ | Operators are public identities |
| `Operator.update_name` | ✅ if `id == actor.operator_id` (PAM-688 fix) | Only the operator's own api_key |
| `Operator.create` | ❌ | Admin-only |
| `OperatorReceipt.read` | ✅ | Public verification artefact |
| `OperatorReceipt.create` | ❌ (PAM-687 fix) | Internal-only — only `SignAndStoreReceipt` |
| `OperatorSigningKey.read` | ✅ | Public verification artefact |
| `OperatorSigningKey.create` | ❌ (PAM-686 fix) | Internal-only — only operator bootstrap |
| `TransparencyAnchor.read` | ✅ | Public verification artefact |
| `TransparencyAnchor.create` | ❌ (PAM-691 fix) | Internal-only — only `AnchorWorker` |
| `ApiKey.create / set_operator / deactivate / update_tier` | ❌ (PAM-689 fix) | Admin-only |
| `ApiKey.read` | ✅ scoped to own row | |
| `ApiKey.increment_draw_count / reset_draw_count` | ❌ (PAM-689 fix) | Internal-only |
| `SandboxDraw.create` | ✅ | Single-shot sandbox rehearsal; operator can run unlimited free |
| `SandboxDraw.read` | ✅ scoped to `api_key_id == ^actor(:id)` | |

### 4.4 Operator with compromised API key

Same capabilities as 4.3. The compromise itself is the threat model: assume
the secret has been exfiltrated. Mitigations:

- The legitimate operator can `:deactivate` the key (via wallop-app admin
  flow which uses `authorize?: false`)
- Monthly tier limits cap the blast radius
- The signed receipt log records every locked draw, so post-incident
  forensics can identify which draws were affected and which operator was
  active at the time

What a compromised key **cannot** do (because of PAM-685..691):

- Mint additional api keys for the same or any other operator
- Substitute the operator's signing key
- Forge transparency anchors
- Rename the operator (unless the api_key happens to be the operator's own)
- Tamper with old draws

### 4.5 wallop infrastructure operator (Dan, plus future team)

Has DB-level access via Railway. Capabilities:

- Direct SQL on production Postgres — including `SET LOCAL session_replication_role = 'replica'` to bypass triggers
- IEx remote shell on the running BEAM node, including `Ash.create(..., authorize?: false)`
- Read access to encrypted operator private keys (decryptable with the production VAULT_KEY)

This is the **highest-trust actor in the system** and the threat model
explicitly assumes wallop-the-company is honest. The mitigations are:

- The transparency log makes retroactive receipt tampering detectable by
  any third-party mirror that snapshots over time
- The protocol spec (`docs/specs/fair-pick-protocol.md`) is published, so
  any consumer can independently verify draws using only public data
- Operator signing keys are encrypted at rest, so a DB dump alone is
  insufficient to forge new signatures (you also need VAULT_KEY)
- Filed as future work: §6 follow-ups around insurance (PAM-655),
  independent crypto audit (PAM-659), and incident response runbook

### 4.6 Future: third-party verifier

A future actor type. A third-party verifier mirrors `/operator/:slug/receipts`,
`/transparency`, and the public proof pages over time. They have no API key,
no special access. Their goal is to independently confirm that:

- Every published draw verifies under the operator's published public key
- The operator's sequence is gap-free where it claims to be, and gaps
  represent legitimately discarded slots
- The transparency log Merkle roots match what the verifier computes from
  their own mirror
- Old draws using the verifier's locally-installed `fair_pick` and `wallop_core`
  versions still verify byte-for-byte

This actor type is the audience for invariants I-1 through I-12. If any
invariant cannot be confirmed by a third-party verifier using only public
data, that's a finding.

---

## 5. Out of scope

What wallop does NOT defend against. Stating these explicitly so an auditor
doesn't waste time on them and so future contributors don't accidentally
broaden the claims.

### Operator behaviour

- **Operator collusion with entrants.** If an operator and an entrant
  collude to rig the entry list, no cryptographic protocol can detect it —
  the operator chose the entries, the protocol just commits to them.
- **Operators publishing rigged entry lists off-platform.** Wallop commits
  to "these specific entries," not "these are the right entries." If the
  operator told their audience there'd be 1000 entries and only added 10,
  that's a contract dispute, not a fairness break.
- **Operators running parallel draws with different entry sets and only
  publishing one.** Currently mitigated by the gap-free operator sequence
  (parallel locks burn sequence numbers visibly), but a determined operator
  with multiple wallop accounts can split their draws across them. Future
  work: per-operator multi-key correlation.
- **Operator going rogue and refusing to publish a draw.** A draw that
  was locked but never executed sits in `:awaiting_entropy` until the
  expiry worker terminates it after 90 days. The signed receipt for the
  lock IS public regardless, so the entries are committed and can't be
  retroactively changed.

### Cryptographic / external

- **drand epoch compromise.** See §1.3.
- **SHA-256 second-preimage attack.** Out of scope. Same risk profile as
  every system using SHA-256.
- **Ed25519 side-channel attacks via OTP `:crypto`.** Out of scope.
- **Quantum cryptography breaking Ed25519.** Out of scope. If this happens,
  every signature scheme on Earth has the same problem.
- **Post-quantum receipt resilience.** Receipts signed today will not
  survive a future quantum attack on Ed25519. Mitigation: re-anchor old
  receipts in a post-quantum signature scheme when one is standardised.
  Tracked as future work, not a current invariant.

### Operational

- **Postgres replication lag / split-brain.** Single-writer assumption.
- **Vault key rotation.** Not currently implemented; rotating the vault
  key requires a re-encryption migration that doesn't yet exist.
- **Backup tampering.** If an attacker modifies a database backup, they
  get a parallel-history wallop universe — but they don't get the published
  receipts or anchors that pin the legitimate history. Out of model:
  attackers who can modify both the live DB and the published artefacts
  are wallop-the-company (see §4.5).
- **Denial of service via expensive endpoints.** Rate limiting exists at
  the tier level (`monthly_draw_limit`); HTTP-level rate limiting exists
  via `WallopWeb.Plugs.RateLimit`. SandboxDraw create is an unaudited DoS
  surface — tracked in the wallop-app PAM-693 follow-up.

### Privacy / GDPR

- **Wallop never stores PII as entry IDs.** `ValidateEntries` rejects
  PII-shaped strings (emails, phone numbers, anything with `@` or `/`).
  The "right to erasure" is satisfied by the operator deleting their own
  ID-to-person mapping; wallop's entry IDs are opaque and not personally
  identifiable.
- **Operator names and slugs are intentionally public.** Operators are
  public identities by design.

---

## 6. Open findings and follow-ups

This document was written immediately after PAM-670 and the PAM-685..691
sweep. All known findings as of 2026-04-08 are tracked in Linear. The
threat model surfaced two new ones (PAM-694, PAM-695) — see §3.

### Active findings

| Card | Status | Description |
|---|---|---|
| **PAM-670** | ✅ Closed (PR #81, v0.11.0) | SandboxDraw resource separation |
| **PAM-685** | ✅ Closed (PR #82, v0.11.1) | Draw.expire policy |
| **PAM-686** | ✅ Closed (PR #82) | OperatorSigningKey authorizer |
| **PAM-687** | ✅ Closed (PR #82) | OperatorReceipt authorizer |
| **PAM-688** | ✅ Closed (PR #82) | Operator authorizer |
| **PAM-689** | ✅ Closed (PR #82) | ApiKey authorizer (the worst one) |
| **PAM-690** | ✅ Closed (PR #82) | Entry authorizer |
| **PAM-691** | ✅ Closed (PR #82) | TransparencyAnchor authorizer |
| **PAM-674** | ✅ Closed (this document) | Threat model writeup |
| **PAM-675** | 🔴 Open, urgent | Receipt completeness audit |
| **PAM-676** | 🟠 Open, high | Action reachability matrix |
| **PAM-677** | 🟠 Open, high | Immutability trigger re-verification |
| **PAM-678** | 🟠 Open, high | Canonical form drift audit (post-entries-table refactor) |
| **PAM-679** | 🟠 Open, high | Ash auth scoping audit (broader) |
| **PAM-680** | 🟠 Open, high | Race condition audit |
| **PAM-681** | 🟠 Open, high | Algorithm version pinning in receipts |
| **PAM-682** | 🟠 Open, high | Colin's four-hour focused topology review |
| **PAM-654** | 🟠 Open, high | Protocol stability CI (frozen vectors + replay) |
| **PAM-659** | 🟠 Open, high | Independent third-party crypto audit |
| **PAM-655** | 🟠 Open, high | Pre-launch legal & insurance |
| **PAM-692** | 🟡 Open, medium | AshPaperTrail version resource hardening |
| **PAM-693** | 🔴 Open, urgent | wallop-app: audit Ash callers after policy hardening |
| **PAM-694** | 🟠 Open, high (this doc) | OperatorSigningKey trigger for append-only enforcement |
| **PAM-695** | 🟠 Open, high (this doc) | Operator slug immutability trigger |
| **PAM-696** | 🟡 Open, medium (this doc) | ApiKey hash format DB constraint |

### Recommended order for the open work

1. **PAM-675** (receipt completeness) — highest probability of finding
   another critical, bounded exercise
2. **PAM-694, PAM-695** (the two new triggers from this doc) — small fixes,
   defence-in-depth on the most load-bearing fields
3. **PAM-676, PAM-677** (action reachability + trigger re-verification) —
   parallel with PAM-675
4. **PAM-678** (canonical form drift) — silent-bug class, worth the time
5. **PAM-681** (receipt algorithm version pinning) — ties into PAM-675's
   findings
6. **PAM-654 layer 1** (frozen vectors at receipt-payload level) — locks in
   everything PAM-675 finds
7. **PAM-679 / PAM-680** (auth scoping + race conditions) — broader audits
   that benefit from PAM-674's matrix as input
8. **PAM-682** (Colin four-hour review) — verification pass after the
   above
9. **PAM-654 layer 3** (historical replay corpus) — long-term regression
   prevention
10. **PAM-659** (third-party audit) — once everything above is closed

### When to update this document

- **Any new resource added to `WallopCore.Domain`** — add it to §4 actor
  capabilities and §3 enforcement matrix
- **Any new invariant promised by the system** — add a row to §2 and §3
- **Any finding fixed** — update §6
- **Any trust assumption change** — update §1
- **Any breaking protocol change** — bump the receipt schema version, add
  a frozen vector, update §2 and §3
