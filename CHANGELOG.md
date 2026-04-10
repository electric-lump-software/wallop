# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### wallop_rs 0.3.0

**Breaking:** `verify_full_wasm` no longer accepts a `count` parameter. Winner count is now extracted from the signed lock receipt after signature verification, closing a trust gap where a caller could pass a different count than what was committed at lock time.

### wallop_rs 0.2.0

New WASM exports for third-party verification:
- `verify_full_wasm` — full end-to-end draw verification (entries → hash → seed → results → receipt signatures)
- `verify_receipt_wasm` — Ed25519 signature verification for lock and execution receipts
- `key_id_wasm` — key fingerprint derivation from public key hex
- `lock_receipt_hash_wasm` — SHA-256 hash of lock receipt payload (for chain linkage verification)
- `build_receipt_payload_wasm` — reconstruct lock receipt canonical payload
- `build_execution_receipt_payload_wasm` — reconstruct execution receipt canonical payload
- `receipt_schema_version_wasm` — extract schema version from receipt payload
- `merkle_root_wasm` — Merkle root computation for transparency log verification
- `anchor_root_wasm` — anchor root computation (combined operator + execution receipt trees)

### wallop_web

- **Full client-side verification pipeline.** The proof page "Verify independently" button now runs an 11-step animated verification: independently compute entry hash and seed, rerun the draw, verify lock and execution receipt Ed25519 signatures, check binding between receipts and computed values (entry hash, seed, results), verify lock_receipt_hash chain linkage, and run a final `verify_full_wasm` double-check. All computation happens in the visitor's browser via the wallop_rs WASM module — no server round-trip.
- **Extract shared verify block component.** The duplicated verification UI between the static proof controller and LiveView proof page is now a single shared component (`VerifyBlock`).

### wallop_core 0.14.1

- **Deploy safety: Oban Lifeline plugin.** Rescues entropy worker jobs stuck in "executing" state after a node restart (deploy, crash). Without this, a deploy that kills a worker mid-execution left the Oban job orphaned and the draw stuck in `pending_entropy` forever. `rescue_after: 2 minutes`.
- **Worker timeout.** EntropyWorker now has an explicit 90-second timeout. Prevents hung workers from running indefinitely and racing with Lifeline rescue.
- **Execution exhaustion → mark_failed.** When entropy fetching succeeds but draw execution fails (e.g. receipt signing error), the draw is now marked as `failed` after max retries instead of staying in `pending_entropy` forever.
- **Lifeline race tolerance.** `fail_draw_with_reason` now handles the case where a draw has already been completed by a concurrent worker (Lifeline rescue race). Returns `:ok` instead of a false error.

### 🚨 BREAKING — wallop_core 0.14.0

- **Draw creation now rejects API keys without an operator.** Previously, creating a draw with an operator-less API key silently succeeded but produced no cryptographic attestation (no lock receipt, no execution receipt, no proof chain). This is now a hard validation error. All silent-skip paths in receipt signing and operator sequence assignment are now hard failures. **Consumer action required:** ensure every API key used for draw creation has an `operator_id` set.

### wallop_core 0.13.2

- **Execution receipt endpoints** — two new public endpoints for third-party verifiers:
  - `GET /operator/:slug/executions` — list execution receipts for an operator (ETag on max sequence, 60s cache)
  - `GET /operator/:slug/executions/:n` — single execution receipt by sequence number (immutable cache, `max-age=31536000`)

  Response shape mirrors operator receipt endpoints: decoded payload, base64 JCS bytes, base64 signature. Verifiers can fetch the payload and signature, then verify independently using the infrastructure public key from `GET /infrastructure/key`.

### wallop_core 0.13.1

- **Transparency log: dual sub-trees + infrastructure signature** — `AnchorWorker` now builds separate Merkle roots for operator receipts and execution receipts, combined with RFC 6962 domain separation: `anchor_root = SHA256("wallop-anchor-v1" || operator_receipts_root || execution_receipts_root)`. The combined root is signed by the infrastructure Ed25519 key, making the transparency log itself infra-key-signed. A verifier who only cares about one receipt type can verify their sub-tree independently. New columns on `transparency_anchors`: `operator_receipts_root`, `execution_receipts_root`, `execution_receipt_count`, `infrastructure_signature`, `signing_key_id`. Existing anchors (pre-this-version) have null values for the new columns.

### wallop_core 0.13.0

- **Execution receipts** — every completed draw belonging to an operator now gets a second signed artefact: an execution receipt signed by the wallop infrastructure Ed25519 key (not the operator's key). The signed payload commits to entropy values (drand randomness, drand BLS signature, weather value), the computed seed, the results, algorithm versions (`wallop_core_version`, `fair_pick_version`), and a `lock_receipt_hash` linking it cryptographically to the lock-time operator receipt. Together, the two receipts let a verifier confirm both halves of the commit-reveal protocol using only signed bytes and public external data.

  New resources:
  - `WallopCore.Resources.ExecutionReceipt` — append-only, one per draw, DB trigger enforced
  - `WallopCore.Resources.InfrastructureSigningKey` — wallop-wide Ed25519 keypair, append-only, Vault-encrypted

  New protocol function:
  - `Protocol.build_execution_receipt_payload/1` — 20-field maximalist signed surface, `execution_schema_version: "1"`

  New endpoints:
  - `GET /infrastructure/key` — raw 32-byte Ed25519 public key with `x-wallop-key-id` header

  New mix tasks:
  - `mix wallop.bootstrap_infrastructure_key` — one-time first-deploy setup
  - `mix wallop.rotate_infrastructure_key` — annual rotation

  **Consumer action required:** if your app parses or displays receipts, you can now fetch and verify execution receipts alongside lock receipts. No changes required for existing lock receipt handling — this is purely additive.

- **PubSub unnamed-node fallback** — `WallopCore.Application` now checks `Node.alive?()` before starting PubSub with the Redis adapter. Unnamed nodes (e.g. one-off mix tasks) fall back to local PubSub instead of crashing.

### 🚨 BREAKING — wallop_core 0.12.0

- **Lock receipt schema v2.** `Protocol.build_receipt_payload/1` now requires seven additional fields and the function's pattern match has changed — callers passing the old 8-key map will get a `FunctionClauseError`. `@receipt_schema_version` bumped from `"1"` to `"2"`.

  New fields in the signed JCS payload:

  | Field | Why |
  |---|---|
  | `winner_count` | Outcome-determining. Was trigger-frozen but not cryptographically committed. |
  | `drand_chain` | Declared entropy source, known at lock time. |
  | `drand_round` | Declared entropy source, known at lock time. |
  | `weather_station` | Declared entropy source, known at lock time. |
  | `weather_time` | Declared entropy source, known at lock time. |
  | `wallop_core_version` | Algorithm version pinning — records which wallop_core ran the draw. |
  | `fair_pick_version` | Carried separately because `mix deps.update fair_pick` can change it independently. |

  Old v1 receipts remain valid. `schema_version` in the payload lets verifiers pick the right parser.

  **Consumer action required:** if your code calls `Protocol.build_receipt_payload/1` directly (unlikely — it's normally called internally by `SignAndStoreReceipt`), add the seven new fields. If your code parses receipt payloads (e.g. for display or verification), handle both `schema_version: "1"` and `schema_version: "2"` shapes.

### 🚨 BREAKING — wallop_core 0.11.0

- **Sandbox draws are now a separate resource** (`WallopCore.Resources.SandboxDraw`) with their own table (`sandbox_draws`), own primary key, no foreign key to `draws`, no `operator_sequence`, no `OperatorReceipt`, and no transparency log membership. Sandbox draws are structurally incapable of being confused with real draws at the schema level. See PR that lands this for the full rationale — short version: the previous design had `execute_sandbox` as an update action on `Draw` gated only by a runtime config flag, the `seed_source` column could be set to `'sandbox'` post-lock, and the signed operator receipt did NOT commit to `seed_source`. Any consumer of `wallop_core` that set `allow_sandbox_execution: true` in its prod config could divert a real locked draw to sandbox execution before the entropy worker ran, with nothing cryptographic to contradict a later claim of "that was only a test." This is now a structural impossibility.
- **Removed from `Draw`:** the `execute_sandbox` update action, its change module (`WallopCore.Resources.Draw.Changes.ExecuteSandbox`), and the `:sandbox` value from the `seed_source` `one_of` constraint (now `[:caller, :entropy]`).
- **Removed from config:** `config :wallop_core, :allow_sandbox_execution` — the action it gated no longer exists.
- **Immutability trigger rewritten:** the `awaiting_entropy → completed` transition is now forbidden entirely. The previous sandbox carve-out is gone. Any row attempting `seed_source = 'sandbox'` is also rejected at the trigger level, belt-and-braces against direct SQL.
- **Migration drops any existing sandbox rows from `draws`** — pre-launch, no real data to preserve. Bypasses the trigger via `session_replication_role = 'replica'` since sandbox rows are typically in terminal state.

#### Migration guide for consumers of wallop_core

1. Bump your `wallop_core` dep to `0.11.0` (git tag).
2. Search your codebase for `Draw.execute_sandbox`, `:execute_sandbox`, or `seed_source: :sandbox` — all three are now gone.
3. Replace the create-lock-execute-sandbox flow with a single `SandboxDraw.create` call:
   ```elixir
   WallopCore.Resources.SandboxDraw
   |> Ash.Changeset.for_create(:create, %{
        name: "My test run",
        winner_count: 3,
        entries: [%{"id" => "ticket-1", "weight" => 1}, ...]
      }, actor: api_key)
   |> Ash.create!()
   ```
   Sandbox draws are create-and-execute in one transaction — no separate lock or execute step.
4. If your app reads sandbox draws separately from real draws, update UI/admin code to query `SandboxDraw` instead of `Draw`. The two resources share no rows, no FKs, no sequence space.
5. Drop any `allow_sandbox_execution` config entries from your `config.exs` / `runtime.exs` files — the key is unused.
6. If your app shows sandbox draws on any public or operator-facing page, consider removing them entirely. Sandbox draws never belong on the real `operator_sequence` registry (`/op/:slug`); real-draw lineage must not be able to accidentally leak sandbox data.
7. Run `mix ash.codegen` in your own repo if you need to generate a migration for any downstream changes. The `sandbox_draws` table is created by wallop_core's own migration and requires no consumer-side schema work.

#### Rate limiting

- Sandbox draws do **not** increment `ApiKey.monthly_draw_count`, do **not** consume monthly tier quota, and are **not** covered by `WallopWeb.Plugs.TierLimit` (which applies to real `Draw` HTTP routes only). Consumers exposing sandbox draws via their own HTTP API should apply their own rate limit — sandbox create-and-execute runs `fair_pick` synchronously on the request path with no entropy wait, making it the cheapest DoS surface in the system if left unprotected. The telemetry event below is the observability hook.

#### Telemetry

- New event: `[:wallop_core, :sandbox_draw, :create]`, measurements `%{count: 1, entry_count: n}`, metadata `%{api_key_id, operator_id, winner_count}`. Sandbox draws are unaudited by design (no receipt, no transparency log), so this event is the only way to observe abuse or unusual volume — attach it to Honeycomb or your alerting pipeline.

### Added

- **Proof PDF embedded fingerprint** — every proof PDF now carries a canonical `proof.json` file embedded as a PDF attachment. The JSON contains the full verifiable record of the draw (`draw_id`, `entry_hash`, `seed`, `drand_*`, `weather_*`, `winners`, signed operator receipt, schema version, template revision, generated timestamp). JCS-canonical (RFC 8785) via the same `Jcs.encode/1` code path used by the operator receipt commitment.
- A third party with only the PDF bytes can extract `proof.json` (e.g. `qpdf --show-attachment=proof.json file.pdf`), parse it, and independently verify the draw against the public receipt log without trusting the rendered HTML inside the PDF. The PDF becomes a self-contained cryptographic artifact, not just a presentation document.
- New `WallopWeb.ProofPdf.Fingerprint` module — pure, no DB or IO. Builds the canonical map and provides `compare/2` for the regeneration invariant.
- **Regeneration invariant**: when regenerating a PDF for an existing draw, the new fingerprint must match the previously-stored sidecar on every field except `template_revision` and `generated_at`. If anything else has drifted (entry hash, seed, winners, receipt) the regeneration is refused with a clear error and a log line listing the drifting fields. Layout-only changes don't trigger this; data drift always does.
- `WallopWeb.ProofStorage` gains `put_metadata/2` and `get_metadata/1` callbacks. Both backends (filesystem and S3) store the canonical fingerprint as a sidecar file (`<draw_id>.json`) next to the PDF.
- `qpdf` installed in the wallop runtime Docker image (~5MB) — used to attach `proof.json` to the Gotenberg-rendered PDF via a one-shot `System.cmd/3` call.
- Frozen test vector for the canonical JSON encoding so any future change to the fingerprint shape breaks loudly.

- **Proof PDF** — certificate-style downloadable proof artifact for completed draws at `GET /proof/:id/pdf`. Rendered from a dedicated HEEx template with print-specific CSS, POSTed as HTML to a sidecar Gotenberg service (https://gotenberg.dev — headless Chromium wrapped in a stateless HTTP API, deployed separately on Railway), returned as PDF bytes. Contains a certificate front page (logo, title, operator, summary, hashes), a verification chain (drand + weather + seed + signed operator receipt), a full anonymised entries appendix, and a verification recipe. Lazy-generated on first request, cached via a pluggable storage backend (filesystem in dev, S3-compatible in production — configured via `AWS_S3_BUCKET_NAME` and friends), served with `Cache-Control: public, max-age=31536000, immutable`.
- `WallopWeb.ProofStorage` behaviour with `Filesystem` and `S3` backends. The S3 backend works against any S3-compatible endpoint (Railway volumes, AWS S3, Cloudflare R2, MinIO).
- "Download PDF certificate" button on terminal proof pages (both the live LiveView and the cached static renderer).
- `eqrcode`, `ex_aws`, `ex_aws_s3`, `hackney`, `sweet_xml` deps on wallop_web. No Chromium in the wallop image — that lives in the sibling Gotenberg service.
- In-progress draws (open / locked / awaiting_entropy / pending_entropy) return 404 with a clear "PDF is only available once the draw has completed" message.
- Tests cover: filesystem storage round-trip, controller 404 for unknown draw, controller 404 for in-progress draw, controller serves cached bytes with the right headers for terminal draws. Tests pre-populate the cache so they never hit Gotenberg.

### Deployment notes

- Deploy `gotenberg/gotenberg:8` as a second Railway service in the same project
- **Remove Gotenberg's public domain** — it has no built-in auth, keep it on the internal network only
- Set `GOTENBERG_URL` on the wallop service to the internal URL (e.g. `http://gotenberg.railway.internal:3000`)
- For local dev: `docker run --rm -p 3000:3000 gotenberg/gotenberg:8`, defaults to `http://localhost:3000`

### Notes

- The PDF inherits the live proof page's entry anonymisation pattern (first character + mask). Both are scheduled to be removed in the entry identifier refactor — until then, the PDF matches what's on screen.
- QR code linking back to the live proof page is a stretch goal, not in this iteration.
- Pre-generation on draw completion (via an Oban job) is also stretch; current behaviour is lazy.

## [0.10.0] - 2026-04-07

### Added

- `ash_paper_trail` extension on `Operator` resource — every change to an operator (create, `update_name`, future mutations) is automatically captured as a row in the new `operators_versions` table. Stores the action name, action inputs, the changes themselves, and the timestamp. Configured in `:changes_only` mode so each version only stores the diff, not a full snapshot.
- `WallopCore.Resources.Operator.Version` Ash resource (auto-derived by `ash_paper_trail`) for querying the version history idiomatically. Added to `WallopCore.Domain`.
- Migration `create_operators_versions` adds the `operators_versions` table with `version_source_id` FK to `operators`, action metadata columns, and a `changes` jsonb column.
- Tests covering create-emits-version, update-emits-version, and rejected-update-does-not-emit-version.

### Notes

- `Operator.update_name` now has `require_atomic? false` because the validation can't be expressed as an atomic SQL update. Functionally identical, slightly less efficient — fine because name changes are rare.
- Consuming apps that maintain their own ad-hoc audit table for operator changes (e.g. `operator_name_changes`) can stop writing new rows after upgrading to 0.10.0 and migrate to querying `Operator.Version` instead. The wallop_core history is the canonical source going forward.

## [0.9.1] - 2026-04-07

### Added

- `WallopCore.DrawPubSub` helper that broadcasts `{:draw_updated, draw}` to both the per-draw topic (`draw:<id>`) and the per-operator topic (`operator:<operator_id>`). All Draw change modules now use this helper instead of calling `Phoenix.PubSub.broadcast` directly. The operator topic broadcast is skipped when the draw has no operator (backward compatible).
- `BroadcastUpdate` change wired into `Draw.create`, `execute_with_entropy`, `execute_drand_only`, and `mark_failed` actions. Previously these actions had no broadcast at all, so the operator registry page never saw new draws or terminal state transitions in real time.

### Fixed

- Operator registry page now updates live when draws are created or change state, instead of staying static until refresh. Consuming apps that pinned `wallop_core ~> 0.9.0` will only get this fix after bumping to `~> 0.9.1`, since v0.9.0 was tagged before the live-update wiring was added.

## [0.9.0] - 2026-04-07

### Added

- **Operator registry** — closes the cross-draw verifiability gap (post-hoc draw shopping: lock → see result → discard → re-lock). Each `Operator` (created by the consuming app or `mix wallop.gen.operator` for self-hosters) gets a public `/operator/:slug` page listing every draw they have ever locked, including discarded and expired ones, with gap-free per-operator sequence numbers. Does not defend against locking parallel draws with different entry sets — operators must follow "one contest = one locked draw"
- `Operator`, `OperatorSigningKey`, `OperatorReceipt`, `TransparencyAnchor` Ash resources
- `Operator.slug` is the canonical identity (immutable, citext, embedded in every signed receipt). `Operator.name` is a mutable display label only, never embedded in any signed payload
- Nullable `operator_id` on `ApiKey` (backward compatible — keys with no operator behave exactly as before)
- Nullable `operator_id` and `operator_sequence` on `Draw`, assigned at create time inside an advisory-locked transaction (gap-free; Postgres sequences explicitly avoided so rollbacks don't leak gaps)
- **Signed commitment receipts** — every locked draw belonging to an operator gets an Ed25519-signed JCS payload (`commitment_hash`, `entry_hash`, `sequence`, `signing_key_id`, `schema_version`, `locked_at`, ...) inserted into `operator_receipts` in the same transaction as `lock`. Failure to sign rolls back the lock — no sequence is burned. Signing keys are Cloak-encrypted via `WallopCore.Vault`; rotation is append-only via additional `OperatorSigningKey` rows with later `valid_from` timestamps
- `Protocol.build_receipt_payload/1`, `sign_receipt/2`, `verify_receipt/3`, `key_id/1`, and `merkle_root/1` (RFC 6962-style). Frozen test vector for the signing path
- **Transparency log** — daily Oban cron worker (`Transparency.AnchorWorker`, runs at 03:30 UTC) builds a Merkle root over all receipts since the previous anchor and pins it to a drand round number. Listed at `/transparency`
- `OperatorController` JSON endpoints under `/operator/:slug`: `receipts`, `receipts/:n`, `keys`, `key` — append-only, cacheable, with ETag on the index and immutable cache on individual receipts
- Proof page now shows "Draw #N by [Operator] (@slug →)" linking to the public registry, plus an expandable signed-receipt panel with the JCS payload, signature, and signing-key id. Renders on both the live and cached static proof pages
- Public registry LiveView with keyset pagination, intersection-observer infinite scroll, debounced case-insensitive search, and a card layout on mobile
- `mix wallop.gen.operator SLUG NAME` — generates an operator and its first Ed25519 keypair, prints the key fingerprint to publish out-of-band
- Append-only PG triggers on `operator_signing_keys`, `operator_receipts`, and `transparency_anchors`
- `(operator_id, operator_sequence)` and `(operator_id, sequence)` unique indexes as belt-and-braces backstops
- Slug denylist, length cap, and Unicode validation on operator name (NFC-normalised, rejects control chars, ZW chars, BOM, line/para separators, bidi overrides, and the tag block) to defend against homograph/spoofing attacks
- Marketing site at `/` with hero, "Why provable?", organiser/developer split, tabbed protocol explainer, origin story, FAQ, and waitlist CTA

## [0.8.0] - 2026-04-07

### Added

- API key tier metadata: `tier`, `monthly_draw_limit`, `monthly_draw_count`, `count_reset_at` (set by wallop-app via `update_tier` action)
- `WallopWeb.Plugs.TierLimit` — enforces monthly draw limit on `POST /api/v1/draws`, returns 429 with tier name and upgrade URL when exceeded
- `WallopWeb.Plugs.KeyRateLimit` — per-API-key rate limit (60 requests/minute, ETS-based), returns 429 with `Retry-After` header
- `IncrementApiKeyDrawCount` change — bumps the actor's monthly_draw_count on successful draw create, auto-resets if `count_reset_at` is in the past
- `increment_draw_count`, `reset_draw_count`, `update_tier` internal actions on `ApiKey`

### Notes

- Per-IP rate limit (`WallopWeb.Plugs.RateLimit`) still runs before auth to protect bcrypt CPU
- Tier metadata is null by default (unlimited) — wallop-app must populate via `update_tier` for paid tiers

## [0.7.0] - 2026-04-03

### Added

- drand relay failover — tries 4 relays (api.drand.sh, drand.cloudflare.com, api2.drand.sh, api3.drand.sh) on transport/5xx errors
- drand-only fallback — if weather is unavailable after 5 attempts, draws proceed with drand entropy only instead of failing
- `weather_fallback_reason` field on draws — stores why weather was skipped, part of the immutable proof record
- `execute_drand_only` Ash action — separate from `execute_with_entropy`, requires fallback reason
- `Protocol.compute_seed/2` — drand-only seed computation (weather_value key omitted from JCS, not null)
- Live retry feedback on proof page — shows attempt count, source status, and drand-only fallback in progress
- Proof chain and timeline show fallback reason for drand-only draws

### Changed

- Retry backoff flattened: 15s, 30s, 45s, 60s, 90s for first 5 attempts, then 120s. Total window ~14 minutes.
- Removed 2-hour failure timeout — Oban's max_attempts (10) handles termination
- EntropyWorker uses `DrandClient.fetch_with_failover/2` instead of `fetch/2`

## [0.6.3] - 2026-04-02

### Added

- Startup warning if a consuming app uses the default Oban prefix — catches the misconfiguration that causes job queue conflicts
- Boundary test enforcing wallop_core has zero references to WallopWeb or WallopApp modules — prevents accidental coupling in future PRs

## [0.6.2] - 2026-04-02

### Fixed

- Add `:inets` to `extra_applications` — fixes OTel exporter startup warning in releases

### Changed

- Document Oban prefix separation for consuming apps — apps sharing the database must use a different Oban prefix to avoid competing for draw jobs (see README)

## [0.6.1] - 2026-04-01

### Fixed

- Draws no longer wait up to 70 minutes for weather observation — removed redundant "observation must be after draw creation" check that rejected valid pre-lock observations. The "within 1 hour of declared weather_time" check is sufficient.

### Changed

- Weather delay reduced from 10 minutes to jittered 3-5 minutes — drand only needs ~30 seconds, no reason to wait longer
- Entropy worker spans now include `draw.weather_time`, `draw.status`, `entropy.weather_observation_time` attributes for debugging
- OTel context propagated into Task.async calls so drand/weather fetch spans appear as children in traces, not orphaned
- Waitlist signup: `WaitlistSignup` Ash resource with `citext` unique email, wired to LiveView form
- Mobile hamburger nav with LiveView toggle
- Anime.js smooth scroll easing for anchor links

## [0.6.0] - 2026-03-31

### Fixed

- **Weather observation pinned to declared time** — WeatherClient now accepts a `target_time` parameter and selects the reading closest to (but not after) the draw's declared `weather_time`, within a 1-hour window. Previously, retries could silently use a different hour's observation, breaking independent verifiability.
- **ExecuteWithEntropy validates observation proximity** — rejects weather observations more than 1 hour from the declared `weather_time`

### Changed

- **Failure timeout reduced from 24h to 2h** — drand resolves in seconds and weather within an hour; 24h was excessive
- **Permanent errors fail immediately** — 401/403 from entropy APIs and invalid responses now fail the draw instantly instead of retrying for hours
- **Oban attempt tracking works correctly** — switched from `{:snooze, _}` (which bypassed attempt counting) to `{:error, _}` with Oban's built-in exponential backoff. `max_attempts` reduced from 20 to 10.
- **Backoff uses Oban's built-in mechanism** — exponential backoff (~30s, ~60s, ~2m, ~4m, ~8m, capped at 15m) instead of custom `compute_backoff` using draw creation time

## [0.5.2] - 2026-03-31

### Added

- Custom OTel spans in Oban workers: entropy collection (drand/weather fetches with source attributes), draw execution, webhook delivery status, expiry candidate counts
- Timestamps on completed proof page timeline stages (full datetime, with fallback to `inserted_at`/`executed_at` for older draws)

### Changed

- Proof page pulse animation: circles now pulse outward repeatedly instead of breathing in and out
- Ecto telemetry handler filters out Oban internal polling queries (`oban_jobs`, `oban_peers`, `oban_producers`)

## [0.5.1] - 2026-03-31

### Fixed

- PubSub broadcasts for all draw state changes: declare_entropy, execute_draw, execute_sandbox, expire, and update_name now push live updates to proof pages and dashboards

## [0.5.0] - 2026-03-31

### Added

- OpenTelemetry instrumentation: Oban job tracing, Ash action tracing, Ecto query spans, Phoenix/Bandit HTTP request spans
- OTLP export to Honeycomb via `HONEYCOMB_API_KEY` env var (auto-creates `wallop` dataset)
- Oban plugin tracing disabled to avoid polling noise — only job lifecycle events are traced

## [0.4.2] - 2026-03-31

### Fixed

- PubSub config: consuming apps (e.g. wallop-app) can provide full PubSub config via `config :wallop_core, :pubsub` for Redis adapter support

### Added

- Redis PubSub adapter for cross-node live draw updates (`REDIS_URL` or `:pubsub` config)

## [0.4.1] - 2026-03-31

### Changed

- Entry operations use Ash API instead of raw Ecto queries (AddEntries, RemoveEntry, Proof, Entries)
- Duplicate entry detection now returns `Ash.Error.Invalid` instead of `Ash.Error.Unknown`

### Added

- API documentation for Entry resource attributes (entry_id PII warning, weight range)
- Description for `entry_count` on Draw
- `citext` Postgres extension

## [0.4.0] - 2026-03-31

### Changed

- **Breaking:** Entries moved from JSONB column to dedicated `entries` table — `entries` attribute removed from Draw, replaced by `entry_count`
- Draw responses include `entry_count` instead of full entries array
- `Proof.check_entry` uses indexed lookup instead of linear scan

### Added

- Direct entry check link: `/proof/:draw_id/:entry_id` auto-checks and pre-fills the entry on page load
- Entries table with immutability trigger (entries locked when draw leaves `open` status)

## [0.3.2] - 2026-03-30

### Added

- Sandbox execution: `execute_sandbox` action with published, deterministic seed (`SHA-256("wallop-sandbox")`) for integration testing
- `seed_source: :sandbox` enum value — honestly labels sandbox draws as non-random
- Proof page banners: purple "Sandbox draw" banner and amber "Not a verified draw" banner for `:caller` seed source

### Changed

- Internal actions (`transition_to_pending`, `execute_with_entropy`, `mark_failed`) now `forbid_if(always())` — prevents external callers from racing the entropy worker with fabricated entropy values

### Removed

- `create_manual` action — all draws now go through the full `create → add_entries → lock` flow with entropy declaration

## [0.3.1] - 2026-03-28

### Fixed

- PubSub registry crash in Oban workers — moved PubSub from `wallop_web` to `wallop_core` to fix cross-app dependency that caused `unknown registry: WallopWeb.PubSub` errors

### Changed

- Webhook delivery now retries transient failures (5xx, network errors) up to 5 attempts with exponential backoff. Permanent failures (4xx, missing draw) are cancelled immediately.

## [0.3.0] - 2026-03-27

### Added

- Optional `name` field on draws (max 255 chars). May be set at creation or updated while the draw is `open`; locked once the draw is locked.
- OpenAPI spec served at `GET /api/open_api` (JSON) and Redoc docs UI at `GET /api/docs`
- Static `priv/openapi.json` committed to the repo; CI verifies it stays in sync via `mix wallop.gen.openapi`
- `mix wallop.gen.openapi` task to regenerate the spec
- Attribute descriptions and GDPR/PII warning in the OpenAPI spec
- Bearer auth security scheme in the OpenAPI spec
- Staged reveal animation on proof page when draw completes (~10 second sequence)
- Dev-only reveal demo page at `/dev/reveal-demo` for visual testing

## [0.2.0] - 2026-03-26

### Added

- Public proof pages at `/proof/:id` with real-time LiveView updates
- Vertical timeline showing draw progress (entries locked → entropy → winners)
- Verification-first completed view with proof chain and external links
- Entry anonymisation (first character + fixed mask)
- Entry self-check form
- Server-side re-verify button
- Tailwind CSS + daisyUI styling
- Countdown timer on proof page during "Fetching Entropy" stage (daisyUI countdown + JS hook)
- 30-second poll loop on proof page as PubSub safety net for reliable real-time updates
- Phoenix LiveDashboard with Obanalyze at `/dev/dashboard` (dev only)
- dotenvy `.env` file support for dev/test configuration
- PubSub broadcasts from EntropyWorker for live updates
- Automatic entropy fetching: drand beacon + Met Office weather observations
- Draw state machine expanded: locked → awaiting_entropy → pending_entropy → completed/failed
- EntropyWorker (Oban): parallel entropy fetch, seed computation, automatic draw execution
- WebhookWorker (Oban): HMAC-SHA256 signed delivery to callback URLs
- DrandClient: HTTP client for drand randomness beacon with chain hash validation
- WeatherClient: Met Office Land Observations client with Decimal pressure normalization
- Callback URL SSRF protection (HTTPS only, no private IPs)
- Lock time entropy declarations (drand round + weather time computed at draw creation)
- Caller-provided seed blocked when entropy sources are declared (Ash + DB trigger)
- 24-hour failure timeout with automatic transition to failed state
- Webhook secret on ApiKey (generated alongside API key)
- Entry structure validation with bounds (max 10k entries, max weight 1000)
- Open draw state: draws accept entries over time before locking (breaking API change)
- `POST /draws/:id/entries` — batch add entries to open draw
- `PATCH /draws/:id/lock` — lock entries and start entropy collection
- Stage 0 "Entries Open" in proof page timeline with live entry counter
- Open draw view on proof page
- Expired draw view on proof page
- ExpiryWorker: hourly Oban cron job expires open draws after 90 days
- `stage_timestamps` field records when each stage transition occurred
- PubSub broadcasts on entry add/remove for real-time proof page updates

### Changed

- Weather entropy: fetch latest available observation instead of exact declared hour
- Weather entropy: reduce wait time from next whole hour (~60 min) to 10 minutes
- Draw schema: new `weather_observation_time` field records actual observation used
- Draw lifecycle: new `open` state replaces one-shot create (breaking API change)
- Draw creation no longer accepts entries — use add_entries + lock flow
- New `expired` terminal state for abandoned open draws (90-day timeout)
- Immutability trigger rewritten: protects `failed`/`expired` states, `winner_count` unconditionally
- Updated mix task output to show webhook secret

## [0.1.0] - 2026-03-24

### Added

- Elixir umbrella project structure (`wallop_core`, `wallop_web`)
- `WallopCore.Protocol.entry_hash/1` — entry list hashing per protocol spec §2.1
- `WallopCore.Protocol.compute_seed/3` — seed computation from entropy sources per protocol spec §2.3
- Protocol test vectors P-1, P-2, P-3 (frozen, canonical)
- GitHub Actions CI (format, credo, tests)
