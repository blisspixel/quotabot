# Changelog

Notable changes to quotabot. Newest first.

## Unreleased

### Added
- Fleet Analytics dashboard: a full-window view over every provider at once,
  opened from a header button. Includes a radar/constellation of remaining
  headroom, a tightest-first headroom ranking, a consumption-share donut, a
  p10/p50/p90 distribution strip, and an aggregated weekday-by-hour
  best-time-to-run heatmap. Pure render over the existing collector analytics.
- CLI release asset packaging helpers: `tools/package-cli.ps1` and
  `tools/package-cli.sh`, each writing the installer asset plus a `.sha256`
  sidecar under `release/`.
- Forward-looking pace analytics: burn rate, runway, pace-vs-reset, and projected
  waste, surfaced in `quotabot stats` and the in-app insights panel.
- Cross-provider meta-analytics: most/least used, and a "barely used, a lower tier
  may be enough" flag once a provider has a week-plus of history.
- Hour-by-weekday headroom heatmap in the expanded insights panel (a "best time to
  run" map), plus day-of-week and hour-of-day profiles.
- In-app Setup and help panel listing each provider's status with inline Connect
  (Grok/Antigravity) or setup tips, and a right-click card menu (set up / hide).
- Routing-aware low-quota alerts: the notification names where to route next.
- Versioned `quotabot.v1` schema on JSON outputs for agent consumers.
- Richer local-runtime detail: loaded model size, quantization, VRAM, context, and
  disk usage.
- New gauge-style app icon matching the in-app mark.
- LM Studio support, and a rethink of how local runtimes are shown. Local
  runtimes (Ollama, LM Studio) have no quota, so they no longer render a usage
  bar. Their card reports installed model count, which model is loaded, and an
  in-use indicator, and they sort below the cloud quota services. Real provider
  icons replace the placeholder dot (a llama for Ollama, a branded hexagon for
  LM Studio). Other OpenAI-compatible runtimes can be added with the shared
  `localRuntimeQuota` helper.
- Historical analytics: headroom is folded into compact hourly buckets retained
  for 90 days. Derives mean and spread, p10/p50/p90 from a histogram,
  reliability, a least-squares trend (percent per day with an R-squared
  confidence), and a by-hour tightness profile. Surfaced as `quotabot stats`
  (human and `--json`) and an expandable in-app insights panel with a sparkline.
- Codex multi-bucket aggregation so usage on one model is not hidden by a fresh
  bucket on another (see Fixed for the user-visible effect).

### Changed
- The desktop binary now uses the public `quotabot` name.
- Cache, history, and analytics writes are atomic (temp file then rename).

### Security
- Token and cache provider names are constrained or sanitized before they become
  local filenames.
- The LiteLLM router only accepts loopback `quotabot_url` values and clamps
  policy TTL/threshold values to bounded ranges.
- Installers validate `QUOTABOT_REPO`, reject malformed checksum sidecars, and
  verify Windows downloads before replacing an existing installed executable.
- Token files are created owner-only before the secret is written, and the auth
  directory is locked down, closing a brief world-readable window on POSIX.
- The local HTTP server returns generic error bodies and throttles the outbound
  provider calls behind a short cache.

### Fixed
- Antigravity now refreshes the Gemini/Antigravity access token from the stored
  refresh token instead of reusing the expired one, so the signed-in account
  reads live instead of falling back to "no live data" after about an hour. A
  reachable free-tier account is reported as free tier rather than missing data.
- The LiteLLM router no longer lets a local fallback preempt a metered provider
  that still has budget.

## Earlier in this cycle

### Added
- Routing recommendation engine (`suggestRoute`): prefers the freest live
  subscription above a comfort threshold and falls back to a local runtime when
  every subscription is low. Surfaced as `quotabot suggest` (human and `--json`),
  the `suggest_provider` MCP tool, and `GET /suggest` on the local HTTP server.
- Ollama adapter: detects a local daemon and reports it as an always-available
  local fallback (`kind: local`); hidden when the daemon is not running.
- LiteLLM proxy plugin (`integrations/litellm/`): a quota-aware pre-call hook
  that routes each request to a deployment with budget, with per-agent steering,
  a local fallback, a usage-metrics logger, and fail-soft behavior. Runs on
  Windows, macOS, and Linux.
- `docs/SETUP.md`: a step-by-step getting started guide.
- `doctor` now prints a next step for each provider (cached to login, no data to
  open the app) and a closing routing suggestion.
- README disclaimer covering trademarks, no-affiliation, and that the user is
  responsible for complying with each provider's Terms of Service.

### Changed
- Usage bars read "X% free" instead of an unlabeled "X%".
- The header timestamp shows an absolute clock time ("as of 8:38 AM"), adding a
  date only once the snapshot is no longer from today.
- `ProviderQuota` gained a `kind` field (`subscription` or `local`).
- Repo layout tidied: contributor docs moved under `docs/dev/`, the dev helper
  moved to `tools/local-setup.ps1`, and internal journals plus build artifacts
  are git-ignored.

### Fixed
- Codex now aggregates the latest snapshot of each model limit bucket across
  recent sessions and shows the binding (most-used) window. Previously it read
  only the newest session, so usage on a different model bucket was invisible
  (a fresh model's 0% masked real weekly usage, reading as a false "100% free").
  Buckets past their reset are treated as fresh when choosing the binding one.
- Codex snapshots carry their real on-disk capture time and are marked stale
  past the window age, so an idle Codex no longer reads as a fresh "100% free".
- The Antigravity last-known-good fallback loads the per-account cache file it
  actually writes (the previous path was never created, so the fallback was
  dead code).
- Headroom selection prefers live data over a fuller but stale cache, and
  excludes local runtimes from winning on their unlimited headroom.
- Windsurf no longer emits duplicate `daily`/`weekly` windows from snake_case
  and camelCase keys.
- History files are size-bounded instead of growing without limit.
- The Grok device-login flow honors the `slow_down` backoff.
- Token files are restricted to the current user on Windows (icacls), matching
  the POSIX `chmod 600`.
- Hardcoded Flutter paths removed from the Windows helper scripts; they now
  discover Flutter on PATH so they work on any machine.
