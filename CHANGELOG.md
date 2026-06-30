# Changelog

Notable changes to quotabot. Newest first.

## Unreleased

### Added
- Manual quota entries can now be added with `quotabot manual set`, listed with
  `quotabot manual list`, and removed with `quotabot manual remove`. They are
  stored locally, appear in normal quota views and JSON as `source: "manual"`,
  and are excluded from measured analytics history.
- `quotabot suggest` and `quotabot models` now accept `--exclude=A,B` to ignore
  specific providers for one routing decision without editing profiles.
- MCP read/routing/reservation/model tools now accept an `exclude` provider-id
  list, giving agents the same one-request provider avoidance available from the
  CLI.

### Fixed
- Grok usage now labels the shared paid-plan pool as a weekly window, matching
  the current Grok Usage tab semantics where Imagine, Chat, and Build are
  category breakdowns inside one shared allowance.
- The desktop widget can now hide one account for a multi-account provider
  without hiding every account for that provider.
- Antigravity setup guidance no longer says persistent login requires custom
  Google OAuth client environment variables.

## 0.5.1 - 2026-06-30

### Security
- Completed a repository-wide adversarial security pass and fixed every
  candidate it found. Cache-only routing now accepts only canonical snapshot
  filenames with non-future timestamps, local cache directories are
  owner-restricted, Windows SQLite loading no longer trusts `WINDIR`, Windows
  ACL grants use the authenticated current-user SID, the LiteLLM router refuses
  HTTP redirects from the loopback quotabot endpoint, LiteLLM agent rules only
  trust key alias or user_id identity, LiteLLM metrics writes are contained
  under `~/.quotabot`, and CI constrains `GITHUB_TOKEN` to read-only contents.

### Changed
- macOS/Linux desktop package verification now includes the required tracked
  Flutter desktop scaffold files and Linux tray indicator development package,
  so native CI package builds exercise the same release bundles users build.
- The 1.0 roadmap final cut is now checked: every roadmap item is marked
  complete, the Windows local gate is green, and GitHub Actions passed the full
  suite plus macOS/Linux desktop package builds on native runners.
- Windows setup now removes legacy `quotabot.ps1`, `quotabot.cmd`, and
  `quotabot.bat` shims from the install directory before copying
  `quotabot.exe`, so stale source-launcher shims cannot shadow the release CLI.
- CI now verifies macOS and Linux desktop release bundle packaging on native
  runners. `tools/package-macos.sh` and `tools/package-linux.sh` build and
  validate the platform bundles, with optional local archives for release work.
- Owner-only local file hardening is now shared across token storage and routing
  lease metadata. Lease directories, lock files, and atomic write files are
  restricted with the same best-effort permissions used for OAuth tokens.
- Parser boundaries now reject non-finite numeric values and clamp direct
  provider percentages to 0..100 before they can reach routing or UI code.
- CI now runs the full suite on Linux, macOS, and Windows (a matrix of
  ubuntu-latest, macos-latest, and windows-latest), so the cross-platform paths
  are exercised on a real host of every claimed OS instead of assumed. The job
  uses bash on every runner (Git Bash on Windows) for consistent multi-line
  steps, and Python is pinned to 3.13 for the coverage gate and current
  `litellm[proxy]` integration tests.

### Added
- The README now has a reproducible animated demo GIF generated from Flutter
  demo screenshot mode. `tools/generate_readme_demo.py` captures the expanded
  widget, compact strip, 90-day analytics view, and demo `top` frame, refreshes
  the static screenshot PNGs, and assembles `docs/quotabot-demo.gif`.
- `quotabot.v1` is now frozen as an additive JSON Schema 2020-12 contract with a
  focused validator and tests. Built-in providers are also listed in a
  compile-time adapter registry, and every adapter now owns a required sanitized
  provider-shape fixture.
- MCP routing tools now accept exact `account` filters in addition to named
  `profile` filters, so routers can query one provider account without creating
  a profile. MCP also exposes `quotas://alerts` and standard
  `resources/subscribe` support: the subscription loop runs the existing
  edge-triggered alert engine and sends `notifications/resources/updated` when a
  provider crosses amber or red.
- MCP routing now has local concurrency leases and a cache-only decision path.
  `reserve_provider` and `release_provider` let parallel routers reserve a
  cloud provider/account locally before dispatch, and active leases reduce later
  `effective_headroom_percent` through `lease_discount_percent`. `decide_now`
  reads only the in-memory or disk last-known snapshot and reports source, age,
  and staleness so per-request routers can make a cheap decision without forcing
  live collection.
- Python and TypeScript MCP client snippets now cover quotabot over both stdio
  and Streamable HTTP. The snippets pin Python consumers to the stable MCP SDK
  v1 line, use the current TypeScript SDK transport imports, keep bearer tokens
  in headers only, print a compact routing decision, and are smoke-tested in CI
  with Python compilation plus strict TypeScript typechecking against the MCP
  TypeScript SDK.
- The MCP server now supports opt-in Streamable HTTP alongside stdio:
  `dart run bin/mcp_server.dart --http` serves the same nine tools and
  `quotas://current`/`quotas://alerts` resources on a loopback-only `/mcp` endpoint with
  DNS-rebinding host/origin checks, batch JSON-RPC rejection, optional bearer
  token auth, and integration tests through the package's Streamable HTTP client.
- A model-catalog audit tool now diffs the committed cloud catalog against
  provider-owned model-list endpoints. `dart run bin/catalog_audit.dart --json`
  emits `quotabot.catalog_audit.v1` with per-provider endpoint ids,
  `missing_from_catalog`, and `catalog_only` sets for OpenAI/Codex,
  Anthropic/Claude, xAI/Grok, and Gemini/Antigravity. It follows provider
  pagination tokens, skips missing API keys without failing by default, redacts
  query-string secrets, filters obvious non-language modalities, and leaves
  context/tools/vision/reasoning/tier fields curated.
- The LiteLLM router is now covered by a real proxy integration test. CI
  installs `litellm[proxy]`, launches a LiteLLM proxy on loopback with the
  actual quotabot `async_pre_call_hook`, serves a fake quotabot `/suggest`
  endpoint and a fake OpenAI-compatible backend, and verifies that a logical
  model is rewritten to the provider with budget. The test is token-free,
  external-network-free, and catches current LiteLLM loader behavior.
- Deterministic property/fuzz tests now cover the untrusted JSON, protobuf,
  gRPC-web, embedded-token, and local-runtime parser boundaries. Sanitized
  provider-shape fixtures for Codex, Claude, Antigravity, Cursor, Windsurf/Devin
  Desktop, Kiro, Grok, LM Studio, and Ollama are loaded from disk as integration
  fixtures.
- CLI simulation mode for deterministic tests: `--mock-provider NAME --state
  STATE` now returns a single synthetic provider snapshot without adapter calls,
  history reads, or burn-history influence. Supported states are `healthy`,
  `low`, `exhausted`, `blocked`, `signed-out`, and `stale`, with process-level
  tests covering JSON snapshots, `check`, `suggest`, and usage errors.
- The desktop app now has full profile controls: create, edit, delete, select,
  provider/account filters, routing policy, theme, and profile-scoped hidden
  providers plus sort. The widget, analytics, notifications, and alert webhooks
  all follow the active profile.
- MCP quota, routing, availability, and model tools now accept optional
  `profile`, applying the same local named profile filters as the CLI while
  preserving the unfiltered `quotas://current` resource.
- CLI quota reads now accept `--profile=NAME`, applying local named profile
  filters before status, JSON snapshots, suggestions, models, checks, stats,
  watch alerts, or top render.
- Named profile foundations now exist in the collector: `quotabot.profile.v1`
  JSON storage, safe profile names, provider/account filters, routing policy
  metadata, and an implicit zero-config default profile.
- Windsurf/Devin Desktop now reads daily and weekly Cascade quota shapes from
  local SQLite state, carries reset timestamps, surfaces account and plan labels
  when present, and no longer invents a 0% quota from undecodable raw blobs.
- Cursor now treats the current included-usage pool as a monthly quota window,
  reads string or blob SQLite state rows, and surfaces account and plan labels
  when local state provides them.
- Multi-account cache fallback now uses a shared tested active-account rule: a
  cached account is shown only while that account is still present in the
  provider's current local account index.
- The desktop widget now groups distinct account identities in the expanded
  view, scopes expansion state by provider/account, automatically disambiguates
  duplicate-provider cards, and keeps provider visibility menu rows unique when
  several accounts exist for the same provider.
- Antigravity now attempts a live read for every discovered active account from
  its cross-platform profile scan, merging duplicate profile records and keeping
  per-account cache fallback limited to accounts still present locally.
- Grok now reads every account present in `~/.grok/auth.json`, tries an
  account-scoped quotabot grant for each one, and caches successful reads per
  account so switching accounts does not overwrite the previous account's
  last-known-good quota.
- Antigravity OAuth login now resolves the signed-in Google email from userinfo
  after token exchange and stores the grant in the matching account-scoped slot
  as well as the provider-default slot. Userinfo failures fail closed and keep
  the default grant path.
- Codex adapter edge-case tests now cover missing session directories, rollout
  files with no `rate_limits`, stale snapshots whose file mtime is fresh, and
  multi-bucket scans that must keep only the newest snapshot per limit bucket.
- OAuth grants can now be stored in independent account-scoped slots as well as
  the existing provider-default slot. The auth filenames contain only a provider
  id plus a hash of the account id, never the raw email, and Grok/Antigravity now
  prefer the account-scoped grant for the detected account before falling back to
  the default grant or host-app token. This is foundation work for the Phase 2
  multi-account edge cases; current zero-config behavior is unchanged.
- `quotabot top` is now fully interactive: navigate the fleet with `j`/`k` or the
  arrow keys, hide a provider for the session with `x` (`h`) and bring them all
  back with `u`, and copy the recommended route to your clipboard with `c` (via
  an OSC 52 terminal escape, so it needs no clipboard dependency). The selected
  row shows a cursor and the footer shows the hidden count and a copy
  confirmation. The keyboard-navigation, hide, clipboard, and selection logic are
  pure, tested functions.
- Stable, documented CLI exit codes a shell or agent can branch on: `0` success,
  `64` usage error (bad argument or unknown provider), and `69` unavailable
  (the named provider for `check`, or the whole fleet for a piped `top`, has no
  usable quota now). For example `quotabot check claude || quotabot suggest`.
- New `quotabot watch` command: polls quota on the adaptive cadence and raises a
  low-quota alert the first time a provider's binding window crosses into red
  (spent or nearly so), naming where to route next ("Claude 5h at 8% free -
  route next to Grok (74% free)"). `--webhook URL` POSTs each alert as
  `quotabot.alert.v1` JSON so the signal can reach a tray toast, a shell, or
  chat; the host must be loopback unless `--allow-external`, so a stray or stale
  URL cannot send even quota metadata off the machine. `--json` emits alerts as
  JSON lines, `--once` runs a single pass (cron-friendly), and `--interval=N`
  pins the poll rate. The decision is a pure, edge-triggered function
  (`computeAlerts`) that fires once per crossing and re-arms only after recovery,
  so a steady spent window never spams; payloads are quota metadata only, never
  prompts, code, or content. The desktop widget raises the same alerts on the
  same engine, and can POST to a webhook configured from its menu ("Alert
  webhook"), loopback-only unless an external host is explicitly allowed.
- The desktop widget now shows the same forward-looking forecast as `quotabot
  top`, on each provider's binding window, in plain language at a glance: a
  runway estimate ("about an hour of usage left") when a window is visibly
  draining, or a plain warning ("likely to run out before it resets") once the
  burn and its history make a strand material. It appears only when there is a
  real burn signal, so a steady fleet shows nothing invented. The decision is one
  shared pure function (`classifyForecast`) used by both the CLI and the widget,
  so the two never drift; each only words it for its own surface. The burn
  estimate now carries its standard error (`Insights.burnSePerHour`) so the
  widget can state a calibrated strand probability rather than a point estimate.
- `quotabot top` is now sortable. Press `s` to cycle the order live (default,
  headroom, burn, strand risk, soonest reset) or start in one with `--sort=NAME`
  (also `QUOTABOT_SORT`); the active mode shows in the footer. The reorder is a
  pure, tested function (`sortProvidersForTop`) that is stable - providers a sort
  cannot rank (no burn history yet, or a local under a cloud-only metric) keep
  their order and sink below the ranked ones, so a cold fleet never reshuffles
  into nonsense. A piped `top` honors `--sort` and still prints one plain frame.

### Changed
- The desktop widget and the analytics screen now draw text from one shared size
  scale (`app/lib/typography.dart`), so the same kind of text is the same size on
  both screens (the few half-point mismatches between the views are gone).

### Added
- `quotabot top` surfaces the forward-looking forecast on each provider's binding
  window: a strand probability (the chance the window is spent before it resets,
  from the same first-passage model `suggest` uses) when burn history makes it
  material, otherwise a plain time-to-empty. The note is colored by urgency and
  only appears when there is a real burn signal - no history, no invented forecast.
  The meter column yields width for it only when a forecast is present, so a steady
  fleet keeps full-width bars.
- `quotabot top` now refreshes on the same adaptive cadence as the desktop app:
  it polls fast when a window is near its cap or a reset is imminent (down to 30s),
  and relaxes to hours when the whole fleet is healthy and resets are far off. The
  cadence is the shared `nextRefreshSeconds` used by the app, so both views agree.
  `--interval=<secs>` still pins a fixed rate, and `r` refreshes on demand. The
  footer shows an "updated Ns ago" indicator so a slow poll is never mistaken for
  a stall.
- `quotabot top` shows each local runtime's detail lines (VRAM, context, models
  installed, disk) under its headline, matching the desktop app instead of a single
  terse status line.
- Truecolor detection for the live view without `COLORTERM`: Windows Terminal
  (`WT_SESSION`) and known truecolor terminals (`TERM_PROGRAM` of vscode, iTerm,
  WezTerm, Ghostty, Hyper, Tabby, Rio, Warp) now render the 24-bit gradient meters.
  `--truecolor` forces it on for any terminal that supports it but is not detected.
- suggest-a-model: `quotabot suggest --task=hard` (or any capability flag) and the
  MCP `suggest_model` tool recommend one concrete model - the cheapest that meets
  the profile and has budget, local-first, escalating to a heavier or paid tier
  only when the requirements force it. Same filters as `models`; quotabot still
  never reads the task. Shapes: `quotabot.suggest_model.v1`.
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
