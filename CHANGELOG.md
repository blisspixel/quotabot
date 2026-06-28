# Changelog

Notable changes to quotabot. Newest first.

## Unreleased

### Added
- Capability-aware model filtering. `quotabot models` and the MCP `list_models`
  tool take a coarse `--task` profile (`simple|standard|hard`) plus explicit
  filters (`--min-context`, `--require-tools`/`--require-vision`/
  `--require-reasoning`, `--tier-floor`/`--tier-ceiling`), returning only the
  models that meet the stated need, most routable first. Each model carries the
  provider's own tier (light/standard/flagship). quotabot never reads the task: the
  caller supplies the profile, and tiers are objective facts, not a quality ranking.
- Color palettes for `quotabot top`: `--theme=<name>` (or `QUOTABOT_THEME`) selects
  `default`, `green` (phosphor CRT), `dark`, `light`, or `synthwave`, and a custom
  palette is a one-liner: `--theme=custom:HEALTHY-TIGHT-LOW-SPENT[-ACCENT]` of hex
  colors. Palettes drive the truecolor gradient meters and accent; 256/16-color
  terminals keep the standard named headroom colors, so a custom palette never
  renders unreadably. A malformed spec falls back to the default.
- A README screenshot of `quotabot top`, the live terminal dashboard, rendered
  from demo data. The collector now has a demo mode (`QUOTABOT_DEMO=1`) so the CLI
  and MCP can show a synthetic fleet without touching any account or history.

### Changed
- The app uses tabular (fixed-width) figures everywhere via the theme, so digits
  line up and the main quota view and the analytics screen render numbers
  consistently.
- The Quota Analytics screen now uses the same rounded-corner card as the main
  quota view, so the window corners are consistent between the two. Screenshots
  regenerated.

## 0.4.0 - 2026-06-28

### Added
- `quotabot calibration`: grades quotabot's own strand predictions against your
  recorded history by replaying the predictor over the hourly buckets it already
  keeps, and reports how often its calls come true as a calibration percentage, a
  Brier score, and a reliability diagram (per provider and overall). No new
  storage and no provider calls. It is honest by construction: a prediction is
  only graded once its horizon has fully elapsed, and it says plainly when there
  is not enough resolved history yet. A `quotabot.calibration.v1` JSON shape too.
- `quotabot top` gains gradient meters: on a truecolor terminal each bar fills
  with a smooth green-to-red gradient that deepens toward exhaustion, with
  color-depth auto-detected (truecolor / 256 / 16 / none) and a clean fall back to
  the single-color bar, plain text, NO_COLOR, and narrow terminals.
- Model registry: `quotabot models` (and the MCP `list_models` tool) list every
  model you can route to right now across cloud providers and local runtimes, each
  tagged with the live budget that gates it (headroom percent, binding window,
  reset) and capability hints (context window, tools, vision, reasoning), most
  routable first. Local-runtime models are read live from the runtime; cloud
  models come from a committed, stamped capability catalog that a refresh tool
  regenerates from each provider's own model endpoint (so it never goes stale by
  hand). The normalized snapshot now carries a provider's `models`, and the
  registry has its own `quotabot.models.v1` shape shared by the CLI and MCP.
- Risk-aware, self-explaining routing. `suggest` (CLI, the MCP `suggest_provider`
  tool, and the local `/suggest`) now estimates each provider's burn-rate
  uncertainty (the standard error of the fitted slope) and exposes, per candidate,
  `burn_se_percent_per_hour`, a first-passage `strand_probability` (the chance the
  binding window is spent before it resets), and a `confidence` (freshness times
  burn-sample adequacy). The payload also carries `as_of` and `risk_z` provenance.
  A new `--risk=Z` flag opts into risk-adjusted ranking: at the default `Z=0` the
  result is identical to before (mean headroom), and higher `Z` discounts
  providers whose burn is uncertain, so a cap being drawn down erratically is
  preferred less than its average headroom suggests. The CLI `suggest` view shows
  the confidence and a strand warning per candidate.

## 0.3.0 - 2026-06-27

### Added
- Lemonade Server now has its own branded lemon logo in the app instead of the
  generic placeholder dot, so every supported provider shows a real mark. The
  provider-to-logo map is pinned by a test, so a newly supported provider that
  ships without a logo is caught. The README screenshots are regenerated from
  demo data so the lemon shows.
- Programmatic screenshot export (`QUOTABOT_SHOTS=1`): the app loads demo data,
  captures the widget and analytics views to transparent PNGs via the real widget
  tree (Flutter's own RepaintBoundary, no OS screen grab), and exits. This keeps
  the README images deterministic and faithful to regenerate.
- `quotabot top`: a live, htop-style dashboard for the terminal. One bar per
  rolling window for every provider, colored on the headroom scale with live
  reset countdowns, local runtimes as always-on fallbacks, a header pool gauge,
  and a route line naming where to send the next request. It redraws in place on
  the alternate screen (wrapped in synchronized-output to avoid tearing),
  repaints countdowns every second, re-collects every `--interval` seconds
  (default 10, minimum 2), and takes `q`/Ctrl-C to quit and `r` to refresh now.
  Honors the binding-window collapse, and degrades to a single plain frame when
  piped or on a dumb terminal. The frame renderer is a pure, fully tested
  function; the ANSI styling is shared with the one-shot CLI output.
- MCP 2025-11-25 depth: every tool now advertises a JSON output schema and returns
  structured content (`structuredContent` alongside the back-compat text block),
  plus read-only/idempotent tool annotations so clients can validate results and
  see that the tools never mutate state. Tool shapes, schemas, and wiring moved
  into a tested `lib/mcp.dart` (the server binary is now a thin shell), covered by
  an in-memory client/server round-trip that exercises the real schema validation.
- System tray for the desktop app: a tray icon with a context menu (show, refresh,
  quota analytics, quit). The window now closes to the tray instead of quitting,
  so quotabot can sit quietly in the background; Quit lives in the tray menu.
- One-command from-source setup: `tools/setup.ps1` (Windows) and `tools/setup.sh`
  (macOS/Linux) build and install the CLI and the desktop app, create a shortcut,
  and finish with `quotabot doctor`. AGENTS.md documents it so an AI agent pointed
  at the repo can set everything up unattended. `tools/create-shortcut.ps1`
  (re)creates the Windows Desktop shortcut on its own.
- Routing suggestions now carry a versioned `schema` (`quotabot.suggest.v1`) and a
  guaranteed non-null `fallback` (a running local runtime, the soonest-resetting
  subscription to wait for, or a passthrough to the requested model), so a caller
  that skips the pick or gets no recommendation always has an actionable next step.

### Changed
- Routing (`quotabot suggest`, the MCP `suggest_provider` tool, and the local
  `/suggest` endpoint) now ranks on burn-aware effective headroom: each
  provider's remaining quota is discounted by its recent burn rate over a
  one-hour planning horizon, so a cap being drawn down fast is preferred less
  than its instantaneous headroom suggests, and a raw-comfortable provider can
  correctly fall back to a local runtime once burn is accounted for.
  Availability still reflects present headroom. The suggestion JSON gains
  `effective_headroom_percent` per candidate, plus `burn_percent_per_hour` when
  local history is available.

### Changed
- Prebuilt CLI binaries cover macOS (Apple Silicon), Linux x64/arm64, and Windows.
  GitHub retired the Intel macOS runner, so Intel Macs build from source
  (`tools/setup.sh`); the installer prints that instead of failing on a missing
  asset.

## 0.2.0 - 2026-06-27

### Added
- Cross-platform release pipeline: pushing a `v*` tag builds the CLI asset
  natively on Linux (x64/arm64), macOS (x64/arm64), and Windows, each with a
  `.sha256` sidecar, so the one-line installers pull a real checksummed binary on
  every OS.
- Quota Analytics: a range-switched view (Now / 7d / 90d) in the same window,
  opened from the header. Now shows ranked headroom with resets and a
  consumption-share donut; 7d/90d recompute from history for the free-%
  distribution, reliability and per-day trend, and a best-time-to-run
  weekday-by-hour heatmap. Carries one math-derived glyph (the only emoji in the
  app), chosen by the fleet's own numbers.
- Antigravity live quota via the Antigravity OAuth client plus the onboarding
  step, so paid accounts read real model quota instead of 403. `quotabot login
  antigravity` now works with no Google Cloud setup and pins a chosen account.
- Full-featured CLI: `status`, `check <provider>`, `json`, `help`, and `version`
  alongside `suggest`/`stats`/`login`/`logout`, with `--json` on every read
  command, color that honors NO_COLOR/CLICOLOR/TTY, and a progress spinner.
- Lemonade Server adapter (OpenAI-compatible local runtime, port 8000, honors
  `LEMONADE_HOST`).
- Demo mode (`QUOTABOT_DEMO=1`) that renders synthetic, account-free data for
  previews and screenshots, plus widget and analytics screenshots in the README.
- Agent and reference docs: `AGENTS.md` (the routing contract), `docs/USAGE.md`,
  `docs/BUILDING.md`, and `docs/PROVIDER_CLIS.md` (each provider's own usage
  command, with a last-updated stamp).
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
- Default provider order leads with the most widely used (Claude, then Codex).
- Header controls reordered to refresh, analytics, collapse, menu, help, close,
  with a clearer bar-chart analytics icon and tooltips.
- README tightened from roughly 390 to 150 lines, with the widget walkthrough,
  analytics, CLI reference, MCP, and build detail moved into linked docs.
- Cache, history, and analytics writes are atomic (temp file then rename).
- Dev tooling refreshed: lints 6.x, CI enforces 85 percent line coverage, and
  `actions/checkout` is on v5.

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
  refresh token instead of reusing the expired one, so the signed-in account no
  longer drops to "no live data" after about an hour. When the per-model quota
  endpoint returns nothing it now says so honestly instead of mislabeling a paid
  account as free tier.
- The Antigravity adapter tolerates a network error in the quotabot-grant path
  (falling back to the CLI/IDE token instead of hard-failing), a non-string tier
  id during onboarding, and no longer assigns a stringified user object as the
  account.
- Google and xAI token responses are decoded inside a guard, so a malformed 200
  can never surface token bytes in an error string.
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
