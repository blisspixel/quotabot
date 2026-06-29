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
**stable**, not a feature count. Everything below is depth on what already exists:
the SEE and ROUTE jobs done flawlessly on every platform, for the providers
quotabot already claims. Adding a new provider does not get us to 1.0; Antigravity
never lying about quota on any OS does.

**Already in place** (the full record is in [CHANGELOG.md](CHANGELOG.md)): the
binding-window SEE rule with honest staleness; self-explaining, risk-aware
`suggest` with provenance (burn standard error, strand probability, confidence,
`--risk`); the per-model registry with capability and tier filters across CLI and
MCP; concrete model recommendation (`suggest --task`); MCP 2025-11-25 output
schemas and read-only annotations; calibration that grades the predictor;
`quotabot top` with gradient meters, palettes, adaptive refresh, and the
forward-looking forecast on the binding window; the cross-platform release
pipeline; and CI green on an 85% coverage floor.

What is left is the ordered plan below. The phases are sequenced deliberately -
each unblocks or de-risks the next - so this is the order to build in, not a menu
to pick from. 1.0 is cut when every box is checked and the suite is green on
Windows, macOS, and Linux.

### Phase 1 - Parity across the surfaces

Finish the features that already half-exist, so the CLI, the widget, and the
alerts all tell the same story.

1. [ ] Interactive `top`: sort (headroom / burn / strand risk / reset), filter or
   hide providers, keyboard navigation, and a one-key "suggest and copy the route
   command", with documented, stable exit codes a shell or agent can branch on.
2. [ ] Forward-looking forecast in the **widget**, in plain language ("about an
   hour of usage left"), matching what `top` already shows.
3. [ ] Proactive low-quota routing alerts: when a window crosses amber/red, name
   where to route next ("Claude 5h at 8% - send the next calls to Grok"), with an
   optional local webhook so the signal can reach a tray toast, a shell, or chat.

### Phase 2 - SEE is flawless on every platform

The real 1.0 promise: every claimed provider reads correctly, everywhere, with no
silent failures. It comes before the deeper testing work because the real runners
it stands up serve every phase after it.

4. [ ] macOS and Linux CI runners, not just Linux.
5. [ ] Real cross-platform verification on macOS and Linux machines, not just
   "code paths ready"; a provider that cannot read says why, plainly.
6. [ ] Token-refresh and onboarding edge cases handled and tested (Antigravity,
   Grok): expiry, multi-account, and signed-out states.
7. [ ] Cursor a first-class read (it keeps rich local state), and each provider's
   plan tier surfaced (e.g. Grok Free vs SuperGrok vs SuperGrok Heavy), so the
   value of the higher tier is visible.

### Phase 3 - Deterministic testability, then hard testing

8. [ ] A simulation mode (`--mock-provider claude --state exhausted`) for
   deterministic core tests - built first here, since the tests below lean on it.
9. [ ] Property/fuzz tests on the untrusted parsers (they ingest external JSON and
   protobuf), plus integration tests against recorded provider fixtures.
10. [ ] LiteLLM plugin covered by real-proxy integration tests.
11. [ ] Model-catalog currency: a refresh/audit tool that diffs the curated
    catalog against each provider's own model list (capabilities stay curated,
    since `/v1/models` endpoints do not expose context/tools/tier).

### Phase 4 - MCP reference depth

Make quotabot the de-facto quota/routing MCP server, on the one routing contract
shared by the CLI, MCP, and the LiteLLM plugin.

12. [ ] Streamable HTTP transport alongside stdio, tested, with capability scoping
    and complete tool-discovery metadata.
13. [ ] Client snippets (Python/TS) so the contract is trivial to adopt.

### Phase 5 - Freeze and ship

Last, once every schema-touching feature above has landed, so the contract frozen
here is the final one.

14. [ ] Freeze the `quotabot.v1` JSON schema and add a compile-time adapter plus
    required-fixture registry, with an "add a provider in 10 minutes" checklist in
    CONTRIBUTING.
15. [ ] A recurring security pass and an adversarial bug-hunt round that returns
    empty (see continuous hardening below).
16. [ ] An animated GIF in the README (the widget collapsing and expanding, `top`
    live, the 90-day analytics view), generated from demo mode so it stays
    reproducible, plus verified macOS and Linux packaging.
17. [ ] Final cut: every box above checked, suite green on Windows, macOS, and
    Linux.

### Continuous hardening (runs throughout, not a phase)

Getting to "exceptional" is a cadence, repeated until it stops finding anything,
in parallel with the phases above rather than after them:

- **Repeated adversarial bug-hunt rounds:** multi-agent sweeps over the whole
  codebase, each finding fixed and pinned with a regression test, run again until a
  round comes back empty.
- **Recurring security reviews:** token handling, host/SSRF validation for local
  runtimes, injection via provider data, and the install supply chain. Each pass
  fixes what it finds.

Self-tuning - using the calibration loop to fit the routing parameters on local
history - and the deeper statistical layers are quality multipliers: valued and
pursued continuously, but not 1.0 gates.

## After 1.0

Breadth and depth, once the core is trusted:

- **More quota-window providers:** Z.ai (GLM), Kimi, Amp, OpenCode, DeepSeek,
  Perplexity. Spend-based aggregators (OpenRouter, Together, Fireworks) only as a
  secondary cost view, since they are dollars, not rolling-window quota.
- **Capability-aware routing, deeper.** The foundation shipped (`--task`,
  `--min-context`, `--require-tools`/`--require-vision`/`--require-reasoning`, tier
  floor/ceiling, cheapest-qualifying-with-budget-wins, local-first, and the
  invariant that quotabot never reads the task). What remains post-1.0 is the rest
  of the knobs (`--budget`, `--exclude`) and a cohesive aggressive local-first mode
  that escalates to a paid plan only when the requirements force it or a window is
  about to reset. Models stay filtered by objective capability and the provider's
  own tier, never a quotabot quality ranking.
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
- **Themes for the widget:** selectable color themes (the `top` palettes already
  shipped), including a high-contrast "hacker" mode, still honoring light/dark.
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
