# Roadmap

Where quotabot is headed and what is deliberately out of scope. For the record of
what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## What quotabot is (and is not)

quotabot does two jobs: **see** how much quota you have left across the AI coding
subscriptions you pay for and your local models, and **route** the next request to
whichever one has budget. The point is simple: never stall mid-flow on a spent
cap, and never leave paid quota sitting unspent.

It **is**:

- a live rolling-window quota monitor (5h / weekly / monthly windows, real resets);
- a routing advisor, available as a CLI, an MCP server, and a LiteLLM plugin;
- local-first and cross-platform (Windows, macOS, Linux), desktop widget plus CLI;
- aware of local runtimes (Ollama, LM Studio, Lemonade) as first-class fallbacks.

It is **not**:

- a cost or dollar-spend ledger (a different, already-crowded category);
- a proxy that sits in your request path (it advises; LiteLLM is an optional add-on);
- telemetry, a cloud service, or an account;
- a model quality or benchmark tool.

That second list matters as much as the roadmap: it is what keeps quotabot from
sprawling into the pile of interchangeable usage dashboards.

## Invariants

Non-negotiables. Every change is held to these; a feature that breaks one is the
wrong feature.

- **Your data is yours, and it stays local.** Your tokens, usage history, cache,
  and preferences live only on your machine. quotabot has no account, no cloud,
  and no telemetry, and never uploads or shares any of it. (This is about your
  data, not about whether quotabot talks to a provider: a request to a provider,
  such as confirming a service is reachable, moves none of your data anywhere and
  is fine.)
- **Never touches user content.** quotabot handles quota and usage figures only.
  It never reads or transmits your prompts, code, or other content; if a feature
  ever talks to a model, it sends only quotabot's own synthetic probe.
- **Credential-careful.** Tokens are stored locked-down (owner-only on POSIX,
  ACL-restricted on Windows), never logged, and never written to JSON output.
- **Never disturb host credentials.** quotabot's own grants are independent;
  refreshing or reading must never invalidate a provider CLI's or IDE's login.
- **Fail soft.** If quotabot is unavailable or its data is stale, callers fall
  back to what they asked for. Routing is an optimization, never a dependency.
- **Honest data.** Surface staleness and age; never fabricate a number. A spent
  longer window overrides a healthy shorter one (the binding-window rule).
- **Cross-platform parity.** Every feature works on Windows, macOS, and Linux
  from one codebase.
- **Pure core, thin adapters.** Logic lives in pure, tested functions; adapters
  are thin I/O shells. The test-coverage floor is enforced in CI.
- **No attribution, no emoji, no em-dashes** in the repo, with the single
  sanctioned exception of the math-derived analytics glyph.

## Road to 1.0

1.0 is a promise that the **core works exceptionally** and the public surface is
**stable**, not a feature count. Everything here is depth on what already exists:
the SEE and ROUTE jobs done flawlessly on every platform, for the providers
quotabot already claims. Adding a new provider does not get us to 1.0; Antigravity
never lying about quota on any OS does.

### What 1.0 needs (the checklist)

The finish line, with honest status. 1.0 is reached when every box is checked and
the suite is green on Windows, macOS, and Linux. The narrative below explains each.

Routing and MCP
- [x] `suggest` explains itself; provenance (`as_of`, risk-adjusted headroom,
  strand probability, confidence, `--risk`)
- [x] MCP 2025-11-25 output schemas and read-only annotations
- [x] per-model registry (`quotabot models`, `list_models`, capability + tier filters)
- [x] `suggest` recommends a concrete model for a task profile (cheapest qualifying
  with budget, escalate on strand)
- [ ] forward-looking prediction surfaced plainly in `top`, the widget, and alerts
- [ ] MCP Streamable HTTP transport alongside stdio, plus Python/TS client snippets
- [ ] LiteLLM plugin covered by real-proxy integration tests
- [ ] model-catalog currency: a refresh/audit tool (capabilities stay curated since
  provider `/v1/models` endpoints do not expose context/tools/tier)

SEE and reliability
- [x] binding-window rule, staleness, honest "no live data"
- [ ] real cross-platform verification on macOS and Linux machines
- [ ] Cursor first-class, and each provider's plan tier surfaced
- [ ] token-refresh edge cases tested (expiry, multi-account, signed-out)

CLI and widget
- [x] `quotabot top` (gradient meters, palettes), `--json` on every read command
- [x] consistent fonts and rounded corners, full provider icon set
- [ ] `top` interactivity (sort/filter/keys, suggest-and-copy) and documented,
  stable exit codes
- [ ] proactive low-quota routing alerts with an optional local webhook

Quality, contract, shipping
- [x] CI green with an 85%+ coverage floor enforced
- [x] cross-platform release pipeline; v0.4.0 shipped
- [x] calibration: `quotabot calibration` grades the predictor against history
- [ ] property/fuzz tests on the untrusted parsers (they ingest external JSON/protobuf)
- [ ] macOS and Linux CI runners, not just Linux
- [ ] a recurring security pass and an adversarial bug-hunt round that returns empty
- [ ] a `--mock-provider` simulation mode for deterministic core tests
- [ ] freeze the `quotabot.v1` schema and add a compile-time adapter+fixture registry
- [ ] an animated GIF in the README

Self-tuning (using the calibration loop to fit the routing parameters on local
history) and the deeper statistical layers are quality multipliers, valued but not
gates for 1.0.

**Quality and hardening (continuous, not a phase)**

Getting to "exceptional" is a cadence, repeated until it stops finding anything:

- **Repeated adversarial bug-hunt rounds.** Multi-agent sweeps over the whole
  codebase, each finding fixed and pinned with a regression test, run again until
  a round comes back empty.
- **Recurring security reviews**, not a one-time pass: token handling, host/SSRF
  validation for local runtimes, injection via provider data, and the install
  supply chain. Each pass fixes what it finds.
- **Validation beyond unit tests:** integration tests against recorded provider
  fixtures, a per-provider `doctor` smoke check, property/fuzz tests on the
  parsers (they ingest untrusted external JSON and protobuf), and real
  cross-platform CI (macOS and Linux runners, not just Linux).

**Reliability (SEE is flawless)**

- Every claimed provider reads correctly on Windows, macOS, and Linux, verified
  on real machines, not just "code paths ready".
- No silent failures: a provider that cannot read says why, plainly.
- Token-refresh and onboarding edge cases are handled and tested (Antigravity,
  Grok), including expiry, multi-account, and signed-out states.
- Depth on providers we already claim: make Cursor a first-class read (it keeps
  rich local state), and surface each provider's plan tier so the difference is
  visible (e.g. Grok Free vs SuperGrok vs SuperGrok Heavy), since people pay for
  the higher tier and want to see what it buys.

**Routing and MCP you can trust (ROUTE earns trust)**

- `suggest` explains itself ("picked X: 91% free, resets soonest").
- Provenance on every payload (`as_of`, staleness/confidence) so a stale route is
  never trusted blindly. (Shipped: burn standard error, risk-adjusted headroom,
  strand probability, and confidence, with a `--risk` opt-in.)
- Forward-looking prediction surfaced plainly: "at this burn, Grok Heavy exhausts
  in ~47 min - throttle to local?" from the runway and strand math, in `top`, the
  widget, and the alerts.
- Fail-soft verified end to end; callers always have a safe default.
- **MCP depth:** complete tool-discovery metadata, capability scoping, a tested
  Streamable HTTP transport alongside stdio, and client snippets (Python/TS), so
  quotabot is the de-facto quota/routing MCP reference. One routing contract,
  shared by the CLI, MCP, and the LiteLLM plugin, with the plugin covered by
  real-proxy integration tests.

**A model registry (what can I run, right now?)**

The flagship that turns quotabot from a quota monitor into a routing primitive any
agentic app can build on. Today it reports quota per provider; the next layer is a
normalized list of the **models** available to you right now, across every
provider and local runtime, each tagged with:

- its provider and account, and the quota window that gates it;
- current headroom and reset (so an agent sees budget per model, not per provider);
- capability hints where known: context length, tool use, vision, reasoning tier.

Sourced from each provider's own model list (Antigravity `fetchAvailableModels`,
Ollama `/api/tags`, LM Studio / Lemonade `/v1/models`, and the lists the CLIs
expose), surfaced as `quotabot models` (CLI), a `list_models` MCP tool, and a
field in the `quotabot.v1` snapshot. With it, `suggest` recommends a concrete
*model*, not just a provider, and any app can use quotabot as its auto-router:
"give me a long-context coding model that still has budget; fall back to local."
This is the CLI/MCP primitive the whole project is in service of, and it must be
rock-solid: stable schema, fail-soft, fast, zero-token.

**An exceptional CLI (the htop view)**

The CLI is the primitive everything else builds on, and it should feel like htop
for your quota plans: open it and the whole fleet is just there, live.

- A `quotabot top` (watch) mode: a refreshing terminal dashboard of every
  provider's windows and your local runtimes, redrawing in place, honoring
  NO_COLOR and degrading to plain text when piped or dumb-terminal. (Shipped.)
- Interactive `top`: sort (by headroom, burn, or reset), filter/hide providers,
  keyboard navigation, and a one-key "suggest and copy the route command", so the
  terminal view is as capable as the widget.
- Considered visuals: truecolor gradient meters, small burn sparklines, clean
  panels, and a pool gauge, degrading cleanly to 256/16/no color and narrow or
  piped terminals. Pleasant to leave open, not just functional.
- Every command fast, scriptable, and `--json`-complete, with documented, stable
  exit codes so a shell or agent can branch on them.
- Identical behavior across Windows, macOS, and Linux terminals.

**Local runtimes, first-class**

- Deeper Ollama / LM Studio / Lemonade reads: load-state, VRAM, context length,
  and tokens/sec where the API exposes them, with graceful degradation when it
  does not.
- A clean onboarding path for any OpenAI-compatible server, so a new local runtime
  is a few lines, not a fork.

**A widget that disappears when you want it to**

- Tray-first quiet mode: tray icon, optional global hotkey, native low-quota
  toasts, with the current frameless card as the expanded view.
- Plain-language low warnings ("about an hour of usage left") alongside the bars.
- Proactive routing alerts: when a window crosses amber/red, say where to route
  next ("Claude 5h at 8% - send the next calls to Grok"), with an optional local
  webhook so the same signal can reach a tray toast, a shell, or chat.
- No layout jank; fast refresh. (Light/dark and text size are already in.)

**A stable contract**

- Freeze the `quotabot.v1` JSON schema, the surface agents depend on.
- A small adapter interface plus a required fixture per adapter (a compile-time
  registry), so the provider set stays correct and is easy to keep correct, with
  an "add a provider in 10 minutes" checklist in CONTRIBUTING.
- A simulation mode (`--mock-provider claude --state exhausted`) for deterministic
  testing of the core.

**Shipping**

- A working release and install pipeline (the one-line install actually installs)
  and verified macOS and Linux packaging.
- An animated GIF in the README (the widget collapsing and expanding, `quotabot
  top` live, the 90-day analytics view) alongside the static screenshots,
  generated from demo mode so it stays reproducible.

## After 1.0

Breadth and depth, once the core is trusted:

- **More quota-window providers:** Z.ai (GLM), Kimi, Amp, OpenCode, DeepSeek,
  Perplexity. Spend-based aggregators (OpenRouter, Together, Fireworks) only as a
  secondary cost view, since they are dollars, not rolling-window quota.
- **Capability-aware routing:** `suggest --min-context`, `--require-tools`,
  `--require-reasoning`, `--budget`, `--exclude`, an optional tier floor/ceiling,
  and an aggressive local-first mode that escalates to a paid plan only when the
  task needs it or a window is about to reset. Task complexity is a coarse,
  caller-supplied profile (quotabot never reads the task); models are filtered by
  objective capability and the provider's own tier, never a quotabot quality
  ranking, and the cheapest qualifying model with budget wins.
- **Concurrency leases** (`reserve` / `release`) so parallel agents do not dogpile
  the same pick.
- **Optimizer features:** use-it-or-lose-it alerts when projected waste at reset
  crosses a threshold; downgrade/upgrade ROI (rolling p90 vs each tier's cap, with
  $/mo saved and breach probability); reset-anchored scheduling.
- **First-class local models (the moat):** VRAM/readiness awareness ("can I run
  70B Q4 right now?", loaded vs cold, tokens/sec) and per-model capability tags,
  so "free" never secretly means a two-minute wait or a flubbed refactor.
- **Richer analytics:** hour-by-weekday heatmap polish, a contribution calendar,
  streaks and summary stats, plan-tier modeling, and provider status polling.
- **Surface routed-request metrics** from the LiteLLM plugin back in the widget.
- **Shareable reports:** a "weekly quota health" markdown export worth posting.
- **Themes:** selectable color themes for the widget and `top`, including a
  high-contrast "hacker" mode, all still honoring NO_COLOR and light/dark.
- **MCP streamable HTTP transport** and client snippets.
- **Ecosystem and packaging:** a plugin model, OS package managers (winget/MSIX,
  Homebrew, AppImage/flatpak), a docs site, and a reusable passive-reader adapter
  taxonomy to widen coverage cheaply.

Differentiators (from a scan of ccusage, CodexBar, ClaudeBar, TokenTracker, and
others) to keep leaning on: a cross-platform widget (most rivals are macOS
menu-bar only), real rate-limit windows (not token or dollar accounting), routing
as a primitive, and first-class local runtimes.

## Not doing (and why)

Deliberately out of scope. Listed so the boundary is explicit.

- **A Rust core or a Tauri rewrite.** Discards a working cross-platform Flutter
  app to chase packaging debt that is real but overstated.
- **Runtime plugin discovery from pub.dev.** Not feasible in an AOT-compiled
  Flutter app; a compile-time adapter registry is the workable form.
- **GitHub Copilot.** For individuals it is a monthly premium-request allowance
  with pay-as-you-go overage, not a rolling-window quota; usage is server-side
  only and the token lives in the OS keyring, not a file. Revisit only if GitHub
  exposes a local premium-request read.
- **Token/dollar cost ledgers as the primary view.** quotabot tracks rolling
  windows, not spend accounting; a cost dimension stays optional and secondary.
- **Pay-as-you-go API vendors** (as quota providers). That is cost, not a
  rolling-window quota.
- **Global leaderboards or cloud sync.** Violates local-first.
- **Browser cookie / OS-keychain decryption.** Platform-specific and
  privacy-sensitive; quotabot reuses tokens the provider's own tools already
  wrote, nothing more.
- **CLI-PTY scraping of `/usage`.** Brittle; prefer the OAuth and file sources.
- **Git-commit / productivity correlation.** Out of the tool's lane.
