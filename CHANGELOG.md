# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed

- Weather entropy: fetch latest available observation instead of exact declared hour
- Weather entropy: reduce wait time from next whole hour (~60 min) to 10 minutes
- Draw schema: new `weather_observation_time` field records actual observation used
- Draw creation now declares entropy sources by default (status: awaiting_entropy)
- Immutability trigger restructured for 5 states with transition validation
- Updated mix task output to show webhook secret

## [0.1.0] - 2026-03-24

### Added

- Elixir umbrella project structure (`wallop_core`, `wallop_web`)
- `WallopCore.Protocol.entry_hash/1` — entry list hashing per protocol spec §2.1
- `WallopCore.Protocol.compute_seed/3` — seed computation from entropy sources per protocol spec §2.3
- Protocol test vectors P-1, P-2, P-3 (frozen, canonical)
- GitHub Actions CI (format, credo, tests)
