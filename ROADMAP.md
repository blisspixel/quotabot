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

**Reliability (SEE is flawless)**

- Every claimed provider reads correctly on Windows, macOS, and Linux, verified
  on real machines, not just "code paths ready".
- No silent failures: a provider that cannot read says why, plainly.
- Token-refresh and onboarding edge cases are handled and tested (Antigravity,
  Grok), including expiry, multi-account, and signed-out states.

**Routing you can trust (ROUTE earns trust)**

- `suggest` explains itself ("picked X: 91% free, resets soonest").
- Provenance on every payload (`as_of`, staleness/confidence) so a stale route is
  never trusted blindly.
- Fail-soft verified end to end; callers always have a safe default.

**A widget that disappears when you want it to**

- Tray-first quiet mode: tray icon, optional global hotkey, native low-quota
  toasts, with the current frameless card as the expanded view.
- Plain-language low warnings ("about an hour of usage left") alongside the bars.
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

## After 1.0

Breadth and depth, once the core is trusted:

- **More quota-window providers:** Z.ai (GLM), Kimi, Amp, OpenCode.
- **Capability-aware routing:** `suggest --min-context`, `--require-tools`,
  `--budget`, `--exclude`, and an aggressive local-first mode that escalates to a
  paid plan only when the task needs it or a window is about to reset.
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
