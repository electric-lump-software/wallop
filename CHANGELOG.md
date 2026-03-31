# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Marketing site at `/` with hero, "Why provable?", organiser/developer split, tabbed protocol explainer, origin story, FAQ, and waitlist CTA
- Waitlist signup: `WaitlistSignup` Ash resource with `citext` unique email, wired to LiveView form
- Mobile hamburger nav with LiveView toggle
- Anime.js smooth scroll easing for anchor links
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
