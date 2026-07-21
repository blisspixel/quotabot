# quotabot

[![CI](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml/badge.svg)](https://github.com/blisspixel/quotabot/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**htop for your agentic-AI quota plans.**

See how much quota you have left across your agentic AI coding subscriptions, in
one place, and route the next request to whichever one has budget, so you can
reduce quota-related stalls and avoid leaving included quota unused.

> Early and under active development (0.x). The core works and is in daily use;
> expect changes on the road to 1.0. See [ROADMAP.md](ROADMAP.md).

quotabot does two things:

1. **Shows your remaining quota** for the rolling-window subscriptions you pay
   for: Claude (Pro/Max), Codex (OpenAI), Antigravity / Gemini (Google), and
   Grok (xAI). It also surfaces what supported **local LLM runtimes** (Ollama,
   LM Studio, Lemonade) have installed or loaded while their daemon is
   reachable, plus a passive hardware-fit estimate for cold local models.
2. **Recommends where to send the next request.** `quotabot suggest` (and the
   same logic over MCP) ranks your subscriptions by confidence-weighted runway
   with a small use-it-or-lose-it boost for measured quota that would otherwise
   expire unused, and can fall back to a reachable local model when subscriptions
   are low, so AI tools and agents can route across accounts instead of guessing
   from a spent short-window bar.

It reuses the tokens your tools already store, so most providers need no setup.
Claude and Codex use account-wide metadata endpoints while a fresh host token or
a local quotabot-owned grant is available. Antigravity reads from a signed-in IDE
or a one-time quotabot login, and Grok can stay live with a one-time quotabot
login.

<p align="center">
  <img src="docs/quotabot-demo.gif" alt="quotabot demo showing the widget, compact strip, 90-day analytics, and top dashboard" width="620">
</p>

<p align="center"><sub>Demo mode: the desktop widget, compact strip, 90-day analytics view, and <code>quotabot top</code>.</sub></p>

Highlights:

- **Cross-platform.** One codebase on Windows, macOS, and Linux.
- **Easy and good-looking.** A small frameless widget that follows the system
  light/dark theme, supports per-profile themes including a high-contrast Hacker
  mode, pins always-on-top or to the taskbar, and collapses to a tiny status
  strip.
- **Useful analytics, no surveillance.** Insight into your own usage patterns
  (distribution, reliability, trend, smoothed and reset-aware best times to
  run). Outputs contain quota and routing metadata, never prompts, code, model
  output, or other user content.
- **Zero usage tokens.** quotabot makes no model or inference call, so its quota
  and routing operations never spend a usage token.
- **Advisor, not a proxy.** quotabot suggests where to send the next request;
  your own tools and agents make the call. It stays out of your request path, so
  there is nothing new to route through and nothing new to trust with your
  traffic - just a content-blind metadata signal that helps you use the
  subscriptions you already pay for.
- **Local-first, your data is yours.** No quotabot account, hosted service, or
  telemetry. Token storage, history, cache, preferences, profiles, and leases
  stay on your machine. Some live adapters present an existing credential only
  to that provider's own metadata endpoint; Antigravity can also perform its
  provider-required account onboarding step before reading quota. External alert
  webhooks remain loopback-only unless you explicitly allow an external host. No
  path sends prompts, code, model output, or other user content.

## What it shows

Each provider is a card that defaults to a tight view: one bar per rolling window
(for example a 5 hour and a weekly window), green when healthy, amber as it
tightens, red when spent, with a reset countdown. A longer window overrides a
shorter one, so a spent weekly cap collapses the card to a single "weekly spent -
resets in 2d" line rather than showing a green 5 hour bar you cannot use. Click a
card to expand it for the full provenance line, model-specific rows, and
analytics; a failed live read, drift, and last-known signals stay on the tight
card because they are always actionable, and a provider that supports quotabot's
own login (Grok, Antigravity) shows an inline Connect button when its read fails.
Local runtimes have no quota, so their
card reports installed and loaded models instead, and acts as a routing fallback.
Cold on-device models are ranked with a conservative metadata-only hardware-fit
signal from current RAM and largest-GPU capacity. It never loads a model or runs
a throughput probe, and it remains advisory because runtimes can split memory.

When a provider offers a redeemable off-cycle reset (Codex's reset credits),
quotabot flags it prominently in green on the card, in `doctor`, and in `top`,
and the desktop app notifies you once, so a spent window shows a way to keep
working now, not just a countdown.

If a fresh provider read moves in a way that contradicts the last trusted read,
quotabot does not replace that trusted cache with the rejected values. The
desktop and `doctor` show **provider drift** with last-trusted quota marked stale
when it exists. Routing excludes that provider from selection, and measured
analytics records no new sample until a clean read establishes recovery.
`quotabot verify` names the failed drift check so the number can be compared with
the provider's own usage view. When an upgrade finds only an older `suspect`
cache record, quotabot cannot prove those windows were ever trusted. It
quarantines them without headroom instead of laundering them through the next
identical read. A later read establishes a new baseline only after every retained
quota reset has
advanced, or after an evidence-class transition.

If a provider has legitimately changed its response shape, recover one exact
quarantined baseline only after comparing it with the provider's own usage view:

```bash
quotabot verify --recover-drift=PROVIDER --account=EXACT_ACCOUNT --yes
```

This performs one targeted live metadata verification and replaces only that
provider/account baseline. It refuses stale, malformed, failed, duplicate,
wrong-account, or concurrently superseded evidence. History and all other local
metadata remain unchanged.

An ordinary live-read failure follows the same evidence rule. Cached quota keeps
its original capture time and last observed percentage. A reset time passing does
not prove the new window is unused, so stale evidence never becomes 100% free and
is never routable.

Every observation also carries a normalized provenance class. Machine output
uses `source_class` with one of six values: `authoritative_live`,
`this_machine_fallback`, `passive_local_evidence`, `local_runtime`,
`status_only`, or `manual`. CLI and report text use the shorter labels
`authoritative`, `this-machine fallback`, `passive local`, `local runtime`,
`status only`, and `manual`. The desktop renders `authoritative_live` as the
plainer scope label `account-wide`; both labels describe the same normalized
class. This class is separate from freshness: a live machine-scoped read can
still omit activity from another device, while an authoritative account read
can become cached. Routing discounts measured
machine-scoped evidence by a `0.7` confidence factor without changing the raw
quota number. `quotabot verify` rejects a class that conflicts with its provider
or data shape. The exact assignments and verification methods are documented in
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md#source-classes).

The same view is available live in the terminal with `quotabot top`, a small
dashboard that redraws in place and, when it has enough history, notes which
window is likely to run out first. Full walkthrough of the widget, analytics, and
CLI: [docs/USAGE.md](docs/USAGE.md).

## Provider status

| Provider     | Source                                                   | Live usage      |
|--------------|----------------------------------------------------------|-----------------|
| Claude       | Account-wide OAuth usage endpoint; fresh Claude Code token or quotabot grant | Yes, while authenticated |
| Codex        | Account-wide ChatGPT usage endpoint; host token or quotabot grant | Yes, while authenticated |
| Antigravity  | Google Cloud Code API (Gemini), token reused and refreshed | Yes, signed-in account; local fallback marked this machine |
| Grok         | gRPC-web billing endpoint, token reused from the CLI     | Yes, when fresh |
| Cursor       | Local credits/state; passive detect for free/Pro          | opportunistic   |
| Windsurf     | Local `cachedPlanInfo` (daily/weekly Cascade quota)       | opportunistic   |
| Kiro         | Local credits/state (CLI+IDE); passive detect             | opportunistic   |
| Ollama / LM Studio / Lemonade | Local server; installed and loaded models | when running |
| NVIDIA NIM | `NVIDIA_API_KEY` or `nvapi` + safe `/v1/models` discovery | free trial available; numeric quota unknown |
| Manual entries | User-entered limit, used count, and reset for any tool  | self-reported   |

Claude and Codex are live with no quotabot login while their host apps maintain
valid credentials. Credential-file presence alone does not make a result live.
Codex reads the ChatGPT usage endpoint using the token Codex stores locally and
fails closed when no account-wide read succeeds. It never opens mixed-content
session files for quota evidence. Because host tokens may expire on an idle
machine, a one-time local `quotabot login claude` or `quotabot login codex` adds
a separate refreshable grant designed to keep the account-wide read live there.
Grants are local and are not synchronized, so run the login once on each idle
machine that needs an independent live read, then use `quotabot doctor` to
confirm that machine's current result. Refresh and expired-host fall-through
have deterministic test coverage; dated real-account validation after an idle
interval remains a tracked 1.0 evidence gate.
Anthropic's usage response does not include a stable account id, so quotabot
also reads the zero-cost OAuth profile metadata with the same credential. Its
account and organization ids are hashed locally into the stable account-pool key
used by snapshots, cache, drift, routing leases, and duplicate collapse. If any
profile identity is unavailable, quotabot falls back to an irreversible
credential-generation fingerprint and keeps at most one successful Claude
credential routable rather than double-counting the plan. Raw credentials and
provider ids never enter quota output or cache files.
Codex applies the same isolation using the ChatGPT account id stored with the
host credential, or a quotabot grant-generation fingerprint when no account id
is available. It ignores response email for evidence identity. Access-token and
refresh-token rotation preserve the same account cache, while a replacement
account or grant cannot borrow the prior account's quota or drift baseline.
Codex also reports named `additional_rate_limits` as sparse model-scoped pools.
For example, GPT-5.3-Codex-Spark can have its own weekly balance while other
Codex models continue to use the shared account window. An explicit null
secondary shared window is treated as absent, not as a broken or full pool.
Antigravity and Grok are live for the account their app is signed into. A host
app token is reused only while it remains fresh. After `quotabot login`,
quotabot can refresh the separate grant it owns; it never rewrites or refreshes
the host application's credential.
Google's consumer Gemini CLI has been superseded by Antigravity, so Google
coverage runs through the Antigravity adapter. Its live Cloud Code quota read is
preferred; local Antigravity settings are only used for account discovery and
offline last-known fallback, where the result is marked "(this machine)". Any
supported OpenAI-compatible local server uses the same normalized local-runtime
shape. Runtime host overrides are eligible as local capacity only when they name
an exact loopback destination. quotabot does not contact a LAN or public host
from these adapters and reports that configuration as unavailable instead.
NVIDIA NIM is an optional free trial signal when
`NVIDIA_API_KEY` or `nvapi` is present: quotabot confirms the key with a
model-list metadata read, but does not invent a numeric balance because NVIDIA
does not expose one without using the service. Because no quota windows are
known, NIM availability is not used as a routable model-budget candidate. With
no key set it reads as a quiet "no live data" setup state with a hint to set the
key, not a red error, since it is opt-in. A key that is present but rejected
still reads as an error.

For exactly where each number comes from, see
[docs/DATA_SOURCES.md](docs/DATA_SOURCES.md); for each provider's own usage
command, [docs/PROVIDER_CLIS.md](docs/PROVIDER_CLIS.md).

Claude's interactive `/usage` command is a human cross-check only. Its current
window bars and reset times are distinct from the contribution breakdown that
Claude labels as approximate and based on local sessions; quotabot never treats
that this-machine breakdown as account balance or cross-device burn. quotabot
does not run `claude -p /usage` or `/quota`: print mode is a prompt-execution
surface, not a stable quota API, and it conflicts with quotabot's zero-inference,
content-blind boundary. quotabot calls the account-wide usage metadata endpoint
directly instead. When that endpoint includes a model-scoped limit such as
Fable, quotabot reports it separately from the shared session and weekly
windows. Spending a scoped model limit makes that model unavailable; it does not
make every Claude model unavailable while shared plan quota remains.

Beginning July 20, 2026, Anthropic says Fable 5 is a standard included benefit
for Max and Team Premium at 50% of limits. Pro and Team Standard retain access
through usage credits and receive a one-time $100 credit. This is a dated plan
policy, not a value quotabot hardcodes. It does not prove the account's current
balance: quotabot requires a current scoped Fable row and applies the tighter of
that row and the shared Claude window before marking Fable available. For the
no-surprise `--budget=quota` filter, Fable additionally requires an explicit Max
or Team Premium entitlement carried by current provider usage or profile
metadata read with that credential on or after July 20, 2026 UTC. A Max or Team
Premium label read from this machine's stored Claude credential is shown as
diagnostic context but does not prove current inclusion after a plan change.
Positive included-quota and credit-backed labels both require that current
provider plan evidence; host-label-only evidence is called unproven. Pro, Team
Standard, and plan-unknown Fable rows remain visible under `--budget=any` but
are not called included quota. Doctor and the desktop
scoped row label the result as `included quota`, `credit-backed availability`,
or `included quota not proven`. See the
[July 17 announcement](https://x.com/claudeai/status/2078302415804379218).

For a tool quotabot does not read yet, `quotabot manual set` adds a local
self-reported quota window. Manual entries appear in the same views and JSON
snapshots with `source_class: "manual"` and the legacy `source: "manual"` hint,
but they are not treated as measured provider telemetry.

## Install

**macOS / Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/blisspixel/quotabot/main/install.sh | bash
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/blisspixel/quotabot/main/install.ps1 | iex
```

These convenience commands trust the bootstrap script delivered by GitHub over
TLS; the downloaded release archive is then checksum-verified. For an
inspect-before-run path and provenance verification, see
[docs/SETUP.md](docs/SETUP.md#inspect-before-running-the-installer).
Before publication, the release workflow redownloads every draft CLI archive on
its native architecture, verifies its checksum and restricted provenance, and
requires both the tagged version and demo-mode `doctor --json` to run. The
scheduled install smoke separately exercises the published one-line installer
and prior-version upgrade on Windows, macOS, and Linux.
The official repository also blocks updates and deletion of `v*` tags. GitHub
[release immutability](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
is enabled prospectively, so releases published after it was enabled on July
18, 2026 lock their tag and attached assets at publication; older releases are
not retroactively made immutable.

Restart your terminal, then run `quotabot doctor`. Claude and Codex should read
live immediately when their host apps have current credentials. Full
getting-started guidance, including idle-machine grants:
[docs/SETUP.md](docs/SETUP.md).

Tagged releases built by the current workflow also contain verified portable
desktop bundles for native Windows, macOS, and Linux. They are separate from the
CLI installer and include checksum sidecars plus build provenance attestations.
See [desktop release bundles](docs/DESKTOP-DISTRIBUTION.md) for exact asset
names, verification, launch, update, rollback, and uninstall instructions. The
current Windows and macOS bundles are not yet application-signed; the guide
keeps that limitation explicit rather than suggesting that an OS warning is safe
to ignore.

To build and install everything from source in one command, run
`pwsh tools/setup.ps1` on Windows or `bash tools/setup.sh` on macOS/Linux (add
`-CliOnly` / `--cli-only` for just the CLI). Windows creates a Desktop shortcut,
Linux installs the app and an application-menu entry, and macOS installs the app
under `~/Applications`. The launchers target stable per-user copies, not build
outputs inside the source checkout. Details in [docs/BUILDING.md](docs/BUILDING.md).

## Keeping providers live on an idle machine

Claude and Codex usually need no quotabot login while their host apps maintain
valid tokens. An idle machine can use a local quotabot-owned grant instead. Grok
and Antigravity still require the local account discovery described in the setup
guide. No cloud project setup is needed:

```bash
quotabot login claude        # opens a browser; paste the code it shows back
quotabot login codex         # opens a browser; loopback capture
quotabot login grok          # device-code flow
quotabot login antigravity   # opens a browser; sign in with the account you want
quotabot doctor              # confirm it reads live
```

Claude and Codex read the same zero-cost account-wide usage endpoints either way;
the grant only changes how the token can be refreshed. quotabot stores its own
refresh token under your per-user config directory, independent of the app's
credentials, and never writes the host app's credential files. A new or rotated
grant is not written unless owner-only permission hardening succeeds. Confirm a
live result with `quotabot doctor`; real-account evidence after an idle interval
is still tracked as a 1.0 acceptance item. Details in
[docs/SETUP.md](docs/SETUP.md#4-keep-a-provider-live-on-an-idle-machine-or-pin-an-account-optional).

## Routing for tools and agents

```bash
quotabot suggest              # balanced provider recommendation
quotabot suggest --local-first  # prefer a reachable local runtime
quotabot suggest --task=hard  # one model, included quota/local by default
quotabot models               # current registry entries, availability, budget, capabilities
quotabot watch                # alert on a low binding window and name the next route
quotabot verify               # test one read for truthful behavior
quotabot verify --require-live # also fail on a cached or failed adapter read
```

The defaults are deliberate:

| Intent | Command | Default ordering and budget |
|---|---|---|
| Pick a provider | `quotabot suggest` | measured subscriptions first, reachable local fallback |
| Prefer local execution | `quotabot suggest --local-first` | reachable local runtime before subscriptions |
| Pick a model | `quotabot suggest --task=hard` | safe `quota` budget by default: measured included quota plus on-device local runtime; then loaded, lighter provider tier, and headroom |
| Filter to local-runtime classification | `quotabot suggest --task=hard --budget=local` | entries reported by supported local-runtime adapters; excludes Ollama cloud-offloaded (`-cloud`) models |
| Opt into unrestricted model spend | `quotabot suggest --task=hard --budget=any` | may recommend credit-backed or paid catalog entries; output states when included quota is not proven |
| Inspect candidates | `quotabot models` | unrestricted `any` listing for inspection; entries remain explicit about availability and `quota_backed` |

`suggest_model` and task-profiled CLI suggestions default to `budget=quota`.
`list_models` and `quotabot models` default to `budget=any` because listing is
inspection, not permission to spend. Choosing one model from credit-backed or
paid catalog entries therefore requires an explicit `budget=any` opt-in.

Ollama can offload cloud models through its local daemon (a `-cloud` tag suffix,
e.g. `qwen3-coder:480b-cloud`) that run on ollama.com, not on-device. quotabot
detects the suffix, flags the model `cloud_offloaded`, and excludes it from
`--budget=local` and free budgets, so an Ollama cloud model never satisfies a
local-only or free policy; it stays listed only under `--budget=any`.

The `OLLAMA_HOST`, `LMSTUDIO_HOST`, and `LEMONADE_HOST` overrides must target
`localhost`, an IPv4 loopback address, or `::1` to qualify as local capacity.
Credential-bearing, LAN, and public endpoints are never contacted by these
local-runtime adapters.

`--use-expiring-quota` applies only to a model suggestion and lets measured
included quota beat local when local history projects meaningful quota would
expire unused soon. `--exclude=A,B` avoids providers for one read.
`--prefer=A,B` states a provider preference that reorders only candidates already
viable (available and above the comfort threshold), so it never revives an
unavailable or spent route; the preference also persists per profile as
`preference_order`. Advanced capability, profile, account, alert, cost-policy,
report, calibration, and provenance commands are documented in
[docs/USAGE.md](docs/USAGE.md).

Provider-routing JSON also includes a content-blind `quotabot.receipt.v1`
decision receipt. It records the snapshot source and age, binding pool, spend
classification, raw and adjusted headroom, every routing adjustment, the
winner's qualification, each alternative's rejection reason, and the fail-soft
fallback. Its deterministic decision id lets an operator correlate the same
decision across CLI, MCP, HTTP, desktop, and LiteLLM without recording a prompt,
source file, model response, credential, or exception.

For agent integration, use the MCP server described in [AGENTS.md](AGENTS.md).
It exposes live and cache-only decisions, model filters, resources, and expiring
local reservations over stdio or opt-in loopback HTTP with bearer auth available.
A smaller
plain loopback JSON endpoint is available for clients that do not speak MCP.
For an execution handoff, the [LiteLLM example](integrations/litellm/) consumes
quotabot's advice with authenticated atomic provider leases and no-surprise
spend classes. Its mutation token is owner-only and never enters a prompt.
Python and TypeScript MCP examples live in
[integrations/mcp_clients/](integrations/mcp_clients/).

## Project layout

```
quotabot/
  app/           Flutter desktop application (Windows, macOS, Linux)
  collector/     Dart package: adapters, normalized model, auth, CLI, MCP server
  integrations/  LiteLLM proxy plugin and MCP client snippets
  docs/          Setup, usage, trust, architecture, strategy, and reference
  tools/         Packaging, icon, and developer helper scripts
```

The app and the collector are both Dart; the app imports the collector directly.
Use the [documentation index](docs/README.md) to find setup, usage, trust, and
integration guides. For product direction see
[docs/PRODUCT-STRATEGY.md](docs/PRODUCT-STRATEGY.md); for design and internals see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Security issues should be reported privately through [SECURITY.md](SECURITY.md).
Development and validation guidance is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer and terms of service

quotabot is an independent, unofficial tool. It is **not affiliated with,
endorsed by, or sponsored by** OpenAI, Anthropic, xAI, Google, Amazon, Cursor,
Codeium/Windsurf, or any other provider. All product names, logos, and trademarks
are the property of their respective owners and are used here only to identify the
service whose quota is being displayed.

quotabot produces quota and routing metadata only. It prefers local state and,
for some providers, makes a bounded authenticated call to that provider's own
quota or model-list endpoint. Antigravity collection can also perform the
provider-required account onboarding request that makes its quota endpoint
available. Normal operation can read credential material and
write local cache, history, preferences, grants, manual entries, and leases; the
credential values are never included in outputs. It makes no model or inference
calls and sends no prompts, code, model output, or other user content. Data stays
local except for provider metadata requests and alert metadata sent to an
external webhook only when the user explicitly enables that host. Even so:

- **You are solely responsible for ensuring your use complies with the Terms of
  Service and acceptable-use policies of every provider you connect to it.**
  Reading local state, reusing stored tokens, or automating routing may be
  restricted by a given provider's terms; review them and stop using quotabot
  with any provider whose terms it would violate for your account.
- Quota numbers are best-effort and may be incomplete, delayed, or wrong. Do not
  rely on them for billing or compliance; verify against the official dashboard.
- quotabot stores any login tokens you create under your user config directory.
  Protect that directory as you would any other credential store.

Provided "AS IS", without warranty, under the [Apache License 2.0](LICENSE). By
using quotabot you accept these terms; if you do not agree, do not use it.
