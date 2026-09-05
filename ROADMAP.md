# Roadmap

Updated 2026-09-05. This file is the forward plan. It records brief shipped
prerequisites only where remaining work depends on them; full shipped work
belongs in [CHANGELOG.md](CHANGELOG.md), implementation detail belongs in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the product reasoning behind
the plan belongs in [docs/PRODUCT-STRATEGY.md](docs/PRODUCT-STRATEGY.md).

## Product contract

quotabot does two jobs:

1. **SEE:** show the best available evidence of remaining AI coding quota and
   local-runtime readiness, including source, scope, age, and uncertainty.
2. **ROUTE:** recommend a usable provider or model for the next request without
   reading the request, entering the inference path, or silently enabling paid
   API spend.

The quality target is not the largest provider list or the most analytics. It is
the fastest path to a truthful answer, the clearest reason for a recommendation,
graceful behavior when providers change, and boring installation and updates.

1.0 means **exceptional and rock-solid: it just works** across every supported
service, on Windows, macOS, and Linux, with at least one quota-based service or
local runtime present. "Just works" includes the realistic case that a person
uses the same account on more than one machine: the quota a user sees must
reflect account-wide truth, not a single machine's stale local copy. Meeting
people where they are with what they have is the point; the product earns trust
by being correct, quiet, and predictable, not by being large.

## Non-negotiable boundaries

- **Zero inference and content-blind.** Runtime code never calls generation
  endpoints and never reads prompts, source code, model responses, or task
  content. Quota reads spend zero usage tokens. Provider print or headless
  prompt commands such as `claude -p` are not quota APIs and are never used as
  collectors.
- **Local-first, not network-free.** History, cache, preferences, profiles,
  grants, and leases are local. Live adapters may send credentials and quota
  metadata to that provider's own metadata endpoint; Antigravity may also run
  its provider-required account onboarding request. An external alert webhook
  can send alert metadata only after the user explicitly enables an external
  host. CLI and desktop release discovery may read public GitHub metadata only
  after a user explicitly checks for or starts an update; it never runs
  automatically.
- **Bounded local writes.** Cache, history, OAuth rotation, profiles, manual
  entries, preferences, alerts, and routing leases are explicit local metadata
  writes. Machine outputs never include secrets.
- **Advisor, never proxy.** quotabot supplies evidence and a recommendation. It
  does not carry the user's request or become a required hop.
- **No surprise bills.** Request-metered API routes are excluded by default.
  Included quota-plan routes require explicit evidence that overages are
  disabled. A runtime reached through a local daemon must not be called local or
  free if execution is actually offloaded to a cloud service.
- **Honest uncertainty.** Staleness, this-machine scope, manual input, passive
  detection, weighted consumption, and unknown balances stay visible. A spent
  binding window overrides a healthier shorter window.
- **Correct across a user's machines.** When a provider exposes an account-wide
  usage read, that read is the source of truth even on a machine the user has
  not actively used the tool on recently. A configured refreshable quotabot
  grant must keep that read live by refreshing its own grant rather than
  depending on the host app to have run there. The implementation and fixtures
  exist; dated real-account idle-machine evidence remains a 1.0 gate. Without a
  usable host credential or local grant, it preserves last-trusted evidence as
  stale and gives an explicit repair step. A machine-scoped fallback is only
  ever shown when nothing account-wide is available, and it is always labeled
  as this-machine.
- **Stale resets prove nothing.** Cached quota keeps its original capture time
  and last observed percentage. A reset boundary passing after a failed live
  read never turns stale evidence into 100% free capacity or a routable result.
- **Scoped limits stay scoped.** A provider-reported model allowance can gate
  that model, but spending it never blocks unrelated models while the
  provider's shared subscription windows still have headroom. A measured scoped
  balance does not prove included-quota spend classification when entitlement
  differs by plan; that classification fails closed without explicit plan
  evidence.
- **Fail soft.** If quotabot is unavailable or lacks a safe route, callers keep
  their original behavior or receive an explicit no-safe-route result. Routing
  is an optimization, not a dependency.
- **Stable contracts.** Public JSON, MCP, CLI, profile, cache, and lease contracts
  evolve additively within 1.x. Breaking changes require a new schema or major
  version.
- **Cross-platform evidence.** Windows, macOS, and Linux are product claims, so
  release evidence must cover native hosts rather than only shared code paths.
- **Pure core, thin adapters.** Decisions and parsing remain deterministic and
  testable. Provider I/O stays isolated and bounded.
- **Machine-enforced quality.** Analyzer, tests, coverage, security checks,
  packaging checks, and contract checks are release gates, not aspirations.

## Next

**Make local-model choices inspectable and useful, then carry the same evidence
into native desktop workflows and named agent harnesses.** Useful product work
continues while publisher identities are unavailable. Signing remains a native
distribution gate before 1.0; store admission is not a product-development gate.

The 0.11.0 release adds inspectable desktop model detail, declared Ollama reasoning
capabilities, honest Windows GPU evidence, and tested advisory harness and
Agent Plugins setup. Further work improves native recovery and execution evidence
before expanding local-only promises.
The September research records the current code baseline, primary sources,
uncertainties, and concrete tests for [local models](docs/research/2026-09-local-models.md),
[native platforms](docs/research/2026-09-platform-quality.md), and
[agent harnesses](docs/research/2026-09-harnesses.md). Those reports are dated
evidence; this section owns the execution order.

**Build in this order**

1. **Establish execution scope before expanding local-only advice.** The
   explicit upstream veto, declared reasoning support, and conservative Windows
   GPU correction are in place. Next, require a bounded positive producer and
   endpoint-scope contract for stronger on-device claims. Preserve unknown
   capabilities and distinguish running context from a model's advertised
   maximum. A local endpoint, loaded model, or host GPU counter must not prove
   on-device execution, active generation, or per-model utilization. Account for
   LM Studio LM Link, WSL and tunnel forwarding, and Lemonade composites before
   admitting those cases to a stronger local-only policy.
2. **Extend inspectable choices across desktop and `top`.** The desktop model
   detail is shipped. Add keyboard-accessible model detail to `top` and a bounded
   comparison of reported capabilities and fit, reusing the same registry and
   displayed snapshot. Answer: what is eligible, what is loaded, which
   context and capabilities are known, why a model is eligible or excluded, and
   what to do when evidence is missing. Show loaded models first, installed
   inventory second, and host pressure separately. Keep useful detail readable
   at narrow widths and larger text sizes.
3. **Make everyday native use dependable.** Prioritize honest GPU evidence and
   runtime reachability, Linux behavior when a tray host is absent, coalesced
   freshness recovery after sleep or foregrounding, and Windows/WSL/host scope.
   Quota refresh now completes independently of advisory analytics; the next
   recovery work must retain that separation and discard older completions.
   Extend supported AMD, NVIDIA, and Apple unified-memory probes only when a
   bounded documented source and native evidence exist. Exercise mixed DPI,
   monitor changes, keyboard, screen reader, startup, quit, and offline recovery
   on the platforms being claimed. Hosted builds and simulated states do not
   establish every hardware or desktop-environment claim.
4. **Make named harness support real.** Start with versioned, tested advisory
   recipes for OpenClaw, OpenCode, Hermes, pi, and NemoClaw. Each recipe must name
   the actual transport or CLI entry point, supported version, OS/runtime
   boundary, model identifier mapping, spend class, and failure behavior. Pin
   the shipped `2025-11-25` protocol and verify legacy compatibility for each
   harness while preparing the published `2026-07-28` revision through a
   separate dual-version test matrix. Package the same advice in the portable
   [Agent Plugins format](integrations/agent_plugin/) where a client supports
   it, with a shipped `quotabot mcp` entrypoint and explicit credential and
   environment prerequisites. The primary integration job is account and plan
   availability advice through supported access under provider terms. MCP
   access does not establish automatic dispatch or permission to bypass a
   limit. Any future explicit model-selection command is secondary and must
   use a documented harness API without inspecting a task or silently rewriting
   host state.
5. **Broaden insights from demonstrated decisions.** Add shared local model
   comparisons, supported hardware evidence, and a bounded llama.cpp metadata
   adapter when the first four steps show a real need. Passive availability and
   readiness histories need a declared user question, bounded retention, and
   explicit source/scope. Keep inferred fit separate from observed behavior;
   do not manufacture throughput, quality rankings, or future prompt counts.

Correctness, credential-lifecycle defects, and broken CI take precedence within
each step. Deliver one reviewable behavior change at a time with its docs and
regression evidence. Steps may overlap where their inputs are independent;
unavailable signing identities or native hardware do not block work that can be
implemented and truthfully validated now.

**Done for each product increment**

- A user can complete the stated job from the default surface and inspect its
  evidence, unknowns, rejection reason, and actionable recovery.
- Collector line coverage remains at least 90 percent and desktop line coverage
  at least 80 percent. Relevant regressions, format, analysis, integrations,
  security, packaging, and the full required three-OS CI pass on the exact change.
- Stable JSON and routing policies remain compatible. No inference call,
  prompt/code read, silent paid fallback, or host credential/state-file write is
  introduced by a collector or integration diagnostic.
- Merge through a short-lived first-party branch after required checks pass,
  return to one current `main`, and remove the merged branch. Publish coherent
  increments as immutable releases with fresh-download and upgrade evidence;
  update release-facing docs only for what those artifacts actually contain.

**September and near-future review**

Use the current research to start implementation now. Recheck primary sources
when touching a runtime or harness, and review the next quarter's candidates
after each shipped milestone. Protocol revisions, new hardware counters, and
new runtime support are contingent on published interfaces and reproducible
evidence, not calendar predictions. Additional providers and paid-credit
visibility keep their separate admission and typed-pool requirements.

**Why this progression:** local capability evidence already exists, but a user
still needs to connect it to an actual model choice. Making that choice visible
improves the daily product and supplies the same trustworthy input to harness
integrations. Native recovery and hardware truth make that experience dependable
on the machines people own. These outcomes can be shipped and measured before
owner-dependent release signing closes.

**Remaining 1.0 release criteria**

- No open reproducible correctness or credential-lifecycle defect. Every fixed
  bug has a regression at the lowest deterministic layer and, when applicable,
  a serialized CLI, MCP, HTTP, or desktop assertion.
- The three-OS required CI matrix is green from a clean main worktree. Coverage,
  static analysis, workflow policy, CodeQL, dependency review, and secret
  scanning pass, with no unresolved actionable dependency advisory in a shipped
  or documented optional lock.
- Real interactive login smoke covers each supported grant flow that automated
  tests cannot complete. A provider consent page alone is never accepted as
  evidence of a successful authorization.
- Windows and macOS artifacts satisfy the signed-release completion criteria
  below after fresh download of the exact draft assets. Keep the explicit
  unsigned disclosure on interim releases until those artifacts have native
  signing evidence; repository readiness is not activation.
- README, setup, building, distribution, and troubleshooting guidance describe
  current behavior and actionable recovery without asking users to weaken a
  platform protection.

### Signed release readiness

**Provision the owner identities, activate the implemented signing paths, and
make signed-artifact verification a fail-closed release gate.** The largest
remaining acquisition gap is the unsigned Windows and macOS distribution path.
Final clean-install, accessibility, and provider evidence should be collected
against the signed artifacts users will actually receive.

The repository path is ready for both platforms. Windows has exact PE catalogs,
isolated Azure Artifact Signing jobs, byte-level Authenticode-only signing delta
checks, native trust and timestamp verification, independent credential-free
packaging validation, and fresh-download checks.
macOS has exact CLI and desktop Mach-O inventories, inside-out signing plans,
  isolated Developer ID jobs, exact signing and stapling delta checks, archive and
  extracted-inventory and code-directory-bound notarization receipts, exact
  entitlement verification, Gatekeeper checks, desktop stapling,
  credential-free packaging, and digest-bound fresh-download checks. Native CI
  also exercises hardened ad hoc signatures against pinned Apple tools. Separate
  Windows and macOS workflows dispatched from protected `main` rehearse both
  credentialed contracts without publishing candidates and retain only bounded
  durable evidence. They and their reviewed `main` and `v*` environment policies
  are implemented, but neither rehearsal has run successfully because owner
  identities, environment values, and Apple secrets are absent. Current
  published artifacts remain unsigned. Owner identity and credential
  provisioning, successful protected rehearsals, mode activation, and one signed
  lifecycle record remain open.

**Behavior**

- Inventory, Authenticode-sign, and RFC 3161 timestamp every shipped PE module,
  including EXE and DLL files, with SHA-256 for both the PE digest and timestamp
  message imprint, then verify every signature before packaging and publication.
- Use an owner-selected hardware-backed Windows signing service. Prefer Azure
  Artifact Signing Public Trust through GitHub OIDC when the owner is eligible;
  use a documented cloud HSM alternative otherwise. Sign only the exact
  validated file catalog and keep private-key material outside GitHub.
- Inventory and Developer ID-sign the standalone macOS CLI, the app, every
  nested Mach-O file, and each native code bundle with hardened runtime. Submit
  eligible distribution containers with `notarytool`, staple the accepted app
  ticket, and verify code signatures plus Gatekeeper assessment before
  publication.
- Preserve the native build, archive-shape, checksum, GitHub provenance,
  lifecycle, verified signed-archive digest, and immutable-publication gates
  around the signed artifacts.

**Guardrails**

- Signing credentials live only in separate protected release environments.
  Pull requests, forks, ordinary branch builds, release compilation, packaging,
  attestation, upload, and verification cannot read them. Only isolated signer
  jobs receive their platform environment between immutable candidate handoffs.
  Windows signer jobs use least-privilege short-lived OIDC. macOS signer jobs
  receive the protected certificate and notary secrets but no OIDC permission.
- Do not provision an exportable PFX for Windows Public Trust. The Windows
  environment uses short-lived OIDC, and verification binds platform trust plus
  the documented durable subscriber identity rather than a rotating leaf
  thumbprint or subject. macOS imports its password-protected Developer ID
  Application P12 into an ephemeral keychain and deletes that keychain on every
  exit path.
- A release tag fails closed and remains unpublished when a required credential,
  signature, timestamp, notarization result, staple, or verification step is
  missing.
- Never print, upload as an artifact, or commit a certificate, private key,
  password, notary credential, or unredacted signing diagnostic.
- Keep checksum and GitHub provenance verification. Application signing proves
  platform identity and integrity; it does not replace repository provenance.
- Do not add instructions that bypass SmartScreen, Gatekeeper, or quarantine.

**Done when**

- The release workflow signs in the correct order, verifies before packaging,
  and fails closed under deterministic missing-secret and bad-signature tests.
- Windows release assets pass `signtool verify /pa /all` plus the bounded
  timestamp message-imprint verifier. After a fresh download of the exact draft
  assets, the macOS CLI passes `codesign --verify --strict` and `spctl --assess`;
  the app passes `codesign --verify --deep --strict`, `spctl --assess`, and
  stapler validation.
- A signed 0.x rehearsal passes clean install, launch, tray, update, rollback,
  data-preserving uninstall, checksum, provenance, and immutable publication on
  native Windows and macOS runners.
- The setup and distribution docs describe the signed state without asking users
  to weaken platform protections.

**Why after stabilization:** unsigned apps are the largest remaining
first-install trust and acquisition gap, and signing is a dependency of the
final native evidence pass. It should authenticate the release candidate users
will actually keep, after reproducible correctness and recovery work has stopped
changing that candidate.
Apple requires Developer ID signing before notarization and recommends hardened
runtime, a secure timestamp, notarization, and ticket stapling for direct
distribution. Microsoft documents Authenticode signing and RFC 3161 SHA-256
timestamping as the authenticity and integrity path for downloaded executables.
Product and native accessibility work should continue before signing. Repeat
the final acquisition and native evidence on the exact signed candidate because
the artifact bytes and platform launch path will change.

Sources: [Apple notarization guidance, accessed 2026-08-20](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Microsoft Windows code-signing options, accessed 2026-08-20](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options),
[Microsoft SignTool guidance, accessed 2026-08-20](https://learn.microsoft.com/en-us/dotnet/framework/tools/signtool-exe),
[Azure Artifact Signing certificate management, accessed 2026-08-20](https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management),
[GitHub deployment environments, accessed 2026-08-20](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
[GitHub OIDC with Azure, accessed 2026-08-20](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure),
[GitHub artifact attestation guidance, accessed 2026-08-20](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

The repository workflow and deterministic verification work are prepared, but
final closure requires the project owner to provision a Windows code-signing
identity, Apple Developer Program membership, a Developer ID identity, protected
release credentials, and successful native rehearsals. Continue native macOS
and Linux provider records, native accessibility smoke, and dated idle-machine
validation of the Claude and Codex grants now; repeat the required evidence on
the signed candidate before the frozen 1.0 rehearsal.

### Local-resource visibility

The stabilization line now includes the narrow, bounded first slice of
content-blind local-resource visibility: loaded model, running context,
model GPU residency, host RAM and VRAM pressure, and optional host GPU
utilization. It is truth and quality-of-life refinement for existing local
runtimes, not a new routing input. Extend this evidence through the product
increments in [Next](#next), with each supported hardware and operating-system
claim backed by the corresponding native evidence.
Expose additional host-scoped CPU, GPU, VRAM, and NPU gauges separately from
runtime-scoped loaded, busy, streaming, and model-residency evidence. Prefer
documented runtime metadata and supported vendor or operating-system counters;
every value must carry source, scope, observation time, and explicit absence
when unsupported.

Host utilization is never attributed to one runtime or model without direct
evidence. Loaded residency is not called active compute. Resource samples remain
ephemeral, never read prompts, code, logs, command lines, or model output, never
require elevation, never modify runtime state, and never enter quota history.
Instantaneous utilization is display-only until native evidence proves a safe
routing use. Require bounded probes, fail-soft behavior, deterministic parser and
schema tests, and dated Windows, macOS, and Linux field validation before
claiming each metric on that platform.

### Credit-backed fallback visibility after stabilization

After the signed lifecycle and typed shared-pool work, add one provider-neutral
way to expose an authoritative purchased-credit, prepaid-unit, or dollar balance
where a provider actually returns it. This is capacity evidence, not a general
spend ledger, and it applies across supported providers rather than only Codex.
Each provider must be assessed independently because a balance can be
account-wide, key-scoped, monthly, expiring, promotional, on-demand, or an
unbounded pay-as-you-go authorization.

Keep four concepts separate in the schema and every human surface: included
subscription quota, promotional quota resets such as Codex banked resets,
purchased or prepaid credits, and unbounded paid API access. A balance record
must carry its amount or units, currency when applicable, scope, source,
observation time, expiry or reset when known, and whether paid continuation or
overages are enabled. Show a value such as "$197.00 paid credits available" only
from an authoritative current provider response. Never derive a balance from
token logs, pricing estimates, model calls, or host application content.

When included quota is exhausted but a paid fallback exists, CLI, `top`,
desktop, MCP, HTTP, and receipts must say that no included quota remains and
label the paid balance separately. Default routing and `budget: quota` continue
to exclude it. Any paid route requires an explicit paid-spend opt-in plus a
provider or account policy that bounds exposure; an available balance never
silently enables overages or automatic paid continuation. Stale, manual,
unknown-currency, unbounded, or drifted evidence cannot satisfy a paid balance
gate.

Start with provider reads that are documented, metadata-only, and usable with
least-privilege authority. Record an explicit unsupported or unverified result
for every current cloud provider rather than fabricating parity. Existing local
runtimes have no provider credit balance, and manual entries remain
self-reported rather than authoritative.

Current provider admission record, researched from first-party documentation on
2026-09-02:

| Provider | Authoritative or supported evidence | Roadmap decision |
|---|---|---|
| Codex | The supported [App Server](https://learn.chatgpt.com/docs/app-server) rate-limit snapshot can include provider-native `credits`, separately from `rateLimitResetCredits`; public API administration exposes historical spend and configured limits, not a documented remaining prepaid balance | First field-validation candidate. Preserve the native unit and ship display-only before any paid policy; never confuse purchased credits with banked resets |
| Claude | Individual [Usage Credits](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans) and Usage Bundles expose balance and controls in Settings, but no supported individual balance API is documented; the Enterprise [Spend Limits API](https://platform.claude.com/docs/en/manage-claude/spend-limits-api) returns an effective limit and informational period-to-date spend, not prepaid balance | Keep additive live response fields optional and display-only. Do not scrape the UI or turn enterprise spend-to-limit into a balance |
| Antigravity | The interactive [`/credits` panel](https://antigravity.google/docs/cli/credits?hl=en) and status line can show AI credits; no documented machine-readable balance API exists, and the host `useG1Credits` setting controls continuation after baseline exhaustion | Never invoke or scrape the TUI and never change the host setting. Require a future stable signed-in metadata field plus explicit quotabot paid opt-in |
| Grok and xAI API | Consumer [Extra Usage Credits](https://docs.x.ai/grok/faq) are documented in Settings only. The separate [xAI Management API](https://docs.x.ai/developers/rest-api-reference/management/billing) has prepaid-balance and postpaid-limit reads, but requires a broad Management key and has unresolved sign, auto-top-up, and overage semantics | Keep consumer credits out until a stable provider field is validated. Defer the management integration until least-privilege read authority and fail-closed billing semantics are proven |
| Cursor | The team [Admin API](https://cursor.com/docs/account/teams/admin-api) reports current-cycle on-demand spend and effective per-user limits, but not the current enabled state; enforcement can lag and Enterprise pooled limits have different meaning | Admit only as display-only `metered_overage` spend-to-cap evidence after explicit admin setup, never as funded balance or default routing |
| Devin and Windsurf | Self-serve [prepaid balance, sharing, and auto-reload](https://docs.devin.ai/admin/billing/self-serve) are documented in Settings; public billing APIs cover different Enterprise ACU surfaces | No collector until a documented self-serve endpoint or stable provider-owned metadata row exists; do not scrape UI or private calls |
| Kiro | Individual client displays can combine plan and [prepaid add-on credits](https://kiro.dev/docs/billing/add-on-credits/); Enterprise exports delayed overage enabled, cap, and used fields | Capture and validate add-on and no-add-on accounts before decomposing local rows. Keep delayed Enterprise export analytical, not live routing evidence |
| NVIDIA NIM | [Catalog access](https://docs.api.nvidia.com/nim/re/docs/api-quickstart) proves status only; no documented numeric hosted credit balance, paid fallback, or reset metadata exists | Retain `status_only`; never infer a balance from catalog access or rate-limit errors |
| OpenRouter candidate | The [ordinary-key read](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key) reports an optional key spending limit, remaining-to-limit, usage, reset, expiry, and BYOK accounting; account-wide purchased credits require a broader Management key | Implement ordinary-key allowance as display-only `paid_api` evidence first. A key-limit remainder is not funded-account proof, so paid routing fails closed without both an explicit opt-in and authoritative bounded funds |

Gemini API [prepaid or postpaid billing](https://ai.google.dev/gemini-api/docs/billing)
is a separate product and identity from
Antigravity or Google One AI credits and must never be merged with either. Google
currently directs prepaid-balance management to AI Studio rather than exposing a
standard API-key balance read.

Acceptance requires sanitized fixtures for zero, positive, expired, unlimited,
malformed, unauthorized, and multi-account balances; exact decimal handling;
accessible paid-spend warnings; no credentials in output; and invariants proving
that paid balances never enter quota stretch, projected-waste, included-quota
headroom, or default routing. Dated field validation must cover each provider
before its balance is claimed. This follows stabilization because the shared
typed balance and spend-policy contract must land once, while provider APIs and
plan semantics remain uneven.

## Current state

The current line, **0.11.1**, is the stable release version and carries
the latest hardening inventory described in [Next](#next). The stable line
contains the implemented
core of the first three milestones below: the truthful substrate (0.6), one
calibrated forecast behind a single decision core (0.7), and the self-tuning
calibration moat (0.8). Those
implementation milestones are not the same as closing every 1.0 evidence gate.
The core product surface exists: CLI, `top`, desktop, analytics, MCP, loopback
HTTP, model registry, profiles, alerts, reports, leases, LiteLLM integration,
verification commands, release automation, and cross-platform CI. Local-model
insights, native quality, and named harness support now advance through the
bounded product increments in [Next](#next). Field validation, accessibility,
signing, and exact native release evidence remain 1.0 gates.
The 0.11.0 increment adds per-model desktop inspection, explicit Ollama
reasoning capabilities, conservative Windows GPU fallback evidence, and
versioned quota-advice setup through `quotabot mcp` and Agent Plugins. Its
[release workflow](https://github.com/blisspixel/quotabot/actions/runs/33956459889)
and unpinned three-platform
[install and upgrade smoke](https://github.com/blisspixel/quotabot/actions/runs/33959135481)
passed, with the matching CLI and desktop installed and verified on Windows.
The 0.11.1 increment separates refresh from advisory work and closes explicit
upstream and embedding-only admission gaps. Each new tag must repeat the
native build and installation gates.
The table is a status index; detailed scope and acceptance criteria live in the
milestone sections below.

| Gate | State | Current evidence | What remains |
|---|---|---|---|
| Core contracts and automated quality | Stable 0.10.3 | Analysis, coverage, schema, security, and release-policy gates are automated; the routing-fallback, partial-cache, exact-identity, profile-isolation, Latest-release, and install-lifecycle regressions are covered; the stable immutable release, unpinned three-OS Latest smoke, and live RC-to-stable update passed | Keep the current stable line green and resolve any new reproducible defect before signing activation |
| Integration trust boundary | Stable 0.10.3 baseline | Loopback, exact-server authentication before bearer disclosure, pseudonymous unauthenticated account labels, request-body deadlines, bounded MCP requests and sessions, proxy-independent Python MCP transport, exact idempotency, LiteLLM reservation behavior, and reviewed optional dependency locks are enforced and tested | Keep packaged guidance and live integration smoke current while field testing continues |
| Provider truth and drift handling | Partial | Drift fails closed; Claude authorization is fixed and live-confirmed end to end; token parsing, account cleanup, explicit disconnect, parser, and cache provenance have deterministic coverage | Validate idle Claude/Codex grants, current Fable entitlement, Windows evidence, and remaining provider response shapes |
| Native provider evidence | Partial | Windows has reported evidence; WSL covers truthful Linux failure behavior | Link dated Windows evidence and verify natural states on native macOS and Linux |
| Provider-ID cache continuity | Stable 0.10.1 | The bounded coordinator, exact role validation, mixed-version locks, durable prepared receipts, crash recovery, branch-conflict quarantine, and empty shipped alias map passed [ordinary hosted CI](https://github.com/blisspixel/quotabot/actions/runs/33542805801), the immutable [candidate release](https://github.com/blisspixel/quotabot/releases/tag/v0.10.1-rc.1), and the complete [three-OS lifecycle](https://github.com/blisspixel/quotabot/actions/runs/33562140830) | Add an alias only for a real provider rename and retain the same fail-closed migration evidence when one exists |
| Installation and update | Stable 0.10.3 | The immutable stable release, unpinned GitHub Latest smoke, three-OS stable-channel, clean install, prior-stable upgrade, persistence, source-setup, and desktop-run matrix passed; the preceding release also has a live RC-to-stable update record | Repeat the complete path on the signed rehearsal and frozen 1.0 candidate |
| Native signing | Repository-ready; inactive | Exact Windows PE and macOS Mach-O inventories and deltas, isolated signer jobs, protected nonpublishing rehearsal workflows, reviewed `main` and `v*` environment policies, deterministic policy and failure tests, credential-free packaging, bounded receipts, and exact draft-asset re-verification are implemented for CLI and desktop; current published artifacts remain unsigned | Provision both owner identities and the exact protected-environment values and secrets, pass native protected rehearsals, activate both modes, and retain one signed 0.x lifecycle record |
| First-run and recommendation comprehension | Ready for evidence | `doctor`, desktop, `suggest`, and `top` share one explanation and decision receipt | Prove on native hosts that a new user understands the route, reason, evidence, spend class, and fallback |
| Accessibility and operator diagnostics | Partial | Automated scaling, labels, targets, contrast, failure-state, and support-safe diagnostic coverage exists | Complete native keyboard and screen-reader smoke and verify every critical failure is actionable |
| Release rehearsal | Stable 0.10.3 baseline complete | The stable release completed the tag, exact 14-asset set, checksum, provenance, fresh download, install, upgrade, state, exact self-update, source setup, immutable publication, unpinned Latest acquisition, and installed stable-channel assertion | Run a signed 0.x rehearsal, then repeat on the frozen 1.0 candidate with interactive provider and accessibility evidence |

Version numbers are not project phases. The logical 0.6 through 0.8 milestones
shipped together in 0.8.0, and 0.9.0 followed. Use patches on the current stable
line for corrective work and 0.x minor releases for coherent new capabilities.
Cut 1.0 when its evidence gates pass.

## Version plan

The milestones below are a logical order of operations, not a schedule. There are
no time estimates. Each version is one coherent capability that the next builds on,
and the order is dependency order: make the inputs truthful, unify them into one
forecast, teach that forecast to grade itself, make its recommendation legible and
opinionated, then make the whole thing boring to install everywhere. The
non-negotiable boundaries above hold at every version; they are the constitution,
not a milestone, and a release that would break one is wrong regardless of its
number.

The ladder follows from what quotabot actually is. Under the meter it is one
object: a calibrated, honest forecast of each resource's availability over time,
shown as two faces from a single local, zero-token, advisor-never-proxy engine -
SEE (the glance) and ROUTE (the suggestion). The meter is commodity and a routing
heuristic is copyable in an afternoon; the durable moat is a calibrated,
self-tuning decision engine grounded in longitudinal local history no competitor
keeps. An exceptional 1.0 therefore ships that engine, not only a hardened meter,
which is why calibration lands before 1.0 rather than after it.

- **0.10.x - stable hardening and signed 1.0 readiness.** Keep the shipped
  explanation and decision-receipt work stable while taking focused corrective
  patches for provider truth, cross-machine correctness, install and update,
  desktop robustness, and documentation. Activate the implemented signing paths
  only after owner provisioning and successful protected rehearsals. Corrective
  patches continue while the next additive product milestone is built.
- **0.11 - local-model inspection and packaged quota advice.** The first
  increment adds desktop model details, explicit Ollama reasoning evidence,
  conservative Windows GPU fallback data, and versioned harness and Agent
  Plugins setup through `quotabot mcp`. Continue with the remaining native
  recovery, terminal model detail, execution-scope, and installed-harness
  evidence in [Next](#next).
- **0.6 - Truthful substrate, core shipped.** Every advertised route means
  exactly what it says on every admitted provider. The remaining field evidence
  and migration hardening listed below are 1.0 acceptance work, not a second
  observation core.
- **0.7 - One forecast, one engine, shipped.** The decision and windowing spine
  is one pure, replayable core that every routing surface consumes, with a
  deterministic replay and simulation harness. Mostly invisible by design.
- **0.8 - The moat: a forecast that grades itself, shipped.** On the forecast
  core, add the calibration ledger - log every prediction with the outcome later
  snapshots reveal, score it (Brier, ECE, reliability), and tune free parameters
  on earlier history only when they improve on later held-out history. Surface a
  precisely named calibration-agreement score only after enough forecasts have
  resolved. A predictor that publishes its evidence cannot bluff. The only
  durable moat and the deepest honesty; it silently makes the glance truer.
- **0.9 - The self-explanatory, opinionated advisor.** With routing resting on a
  calibrated forecast, make it legible and aligned to the user: one plain-language
  explanation shared by every surface, one unified decision receipt, an explicit
  spend-order and provider-preference policy, local-first QOL, and multi-account.
  The visible product payoff, resting on an engine that has earned trust.
- **1.0 - Exceptional and rock-solid: it just works.** The quality bar in "1.0
  definition of done": native prebuilt desktop acquisition on every claimed OS,
  real native macOS and Linux evidence, accessibility smoke on native hosts, a
  boring clean-host install / update / uninstall / rollback lifecycle, every gate
  green on the frozen candidate, honest docs, and no known blocker - then rehearse
  until the cut is boring, and cut.
- **1.x - stabilization, then ranked outcomes.** The first 30 days are
  stabilization only (below). After that, the remaining ranked outcomes land
  additively without breaking a published 1.x contract: MCP compatibility
  maintained deliberately, quota modeled as a typed shared pool before any weighted
  coding plan, multi-agent reservations hardened at volume, then distribution
  channels and admission-gated providers.
- **2.0 - only to change an invariant or a stable contract.** No 2.0 is planned;
  it exists solely as the escape hatch if a non-negotiable boundary or a public
  JSON/MCP/CLI/profile/cache/lease contract must change. Provider count and
  analytics breadth never justify a major version.

## 1.0 definition of done

1. Every claimed provider is assigned a source class: authoritative live,
   this-machine fallback, passive local evidence, local runtime, status-only, or
   manual. Each class has a documented routing rule, drift response, and
   verification method.
2. Deterministic fixtures cover healthy, low, exhausted, signed-out, stale,
   multi-account, reset-edge, malformed, and provider-drift states. Real-host
   evidence covers every naturally available state; unavailable states are
   marked fixture or not applicable rather than blocking forever.
3. No spent, stale, capability-exhausted, unverified manual, offloaded-cloud, or
   surprise-billing route can win a policy that excludes it.
4. A normal recommendation states what to use, why it won, how current and
   authoritative the evidence is, the applicable spend policy, and the fail-soft
   fallback. Advanced factors remain inspectable without dominating the default
   copy.
5. Public JSON, MCP, CLI, profile, cache, and lease contracts pass compatibility
   tests and are documented accurately.
6. The CLI installs from a verified release artifact with one documented path,
   and update, uninstall, data preservation, and rollback behavior are explicit.
7. The desktop surface has a native prebuilt acquisition path on every claimed
   OS, with no Flutter SDK required for normal use, or it is clearly labeled a
   source-built preview and removed from the primary 1.0 promise. The preferred
   outcome is a prebuilt first-class desktop surface.
8. Critical desktop and terminal flows pass keyboard, focus, text scaling,
   contrast, reduced-motion, and basic screen-reader smoke checks on native
   hosts.
9. Provider, auth, cache, webhook, integration, and alert failures are visible
   through bounded user copy, structured output, logs, or verification records.
10. Runtime paths contain no paid generation endpoint, credential leak, unsafe
    external bind, or silent external webhook behavior.
11. CI, lint, tests, collector and desktop coverage floors, CodeQL, secret scan,
    dependency review, packaging checks, checksums, and provenance checks pass
    on the final commit and tag.
12. README, setup, usage, data-source, schema, architecture, security, agent, and
    release docs describe the shipped artifacts without absolutes the product
    cannot guarantee.
13. No known release-blocking correctness, billing, credential, data-loss,
    installation, accessibility, or security issue remains open.
14. For every provider with an account-wide usage read, that read stays live on
    a machine the user has not actively used the host app on recently, by
    refreshing quotabot's own credentials without requiring a fresh host token
    and without writing the host app's credential files. Host state may still be
    read for bounded credential or account discovery. When a live read cannot
    succeed, the number is shown stale with an actionable next step, never as a
    confident current value; a passed reset never changes stale evidence to
    100% free, and any machine-scoped fallback is labeled this-machine.

## The path to 1.0, in detail

Dependency order, not a schedule. Each subsection is a milestone from the version
plan with its concrete work and its acceptance test. Items already shipped on the
0.5.x line are noted where they complete part of a milestone; the full history is
in the changelog.

### 0.6 - Truthful substrate

**Outcome:** every advertised route means exactly what it says, on every claimed
provider, before a forecast is built on top of it.

- Provider identity aliases for renames. **Done in stable 0.10.1:** a one-way
  `kProviderIdAliases` map plus `canonicalizeProviderId`, funnelled through every
  identity seam (profile/hidden/filter/manual normalization, adapter resolution,
  lease keys, cache filename stems), so registering a rename preserves the user's
  durable state and routing resolution. The map is empty until a real rename
  ships (identity, zero behavior change), and guard tests keep it one-way and
  stop it shadowing a live provider. The rc.15 claim-backed cache evidence guard
  and the role-aware migration specified in [Next](#next) now carry validated
  cached snapshots, drift, history, buckets, and analytics checkpoints through
  a rename. The unchanged suite passed ordinary hosted Windows, macOS, and
  Linux CI from signed `main`, then the complete candidate release, install,
  update, and source-setup lifecycle before stable promotion.
- **Done:** new account-scoped snapshots, drift records, history, analytics
  buckets, evidence locks, and lease grouping use collision-resistant opaque
  account keys. During a one-way upgrade, exact-account legacy evidence remains
  readable, snapshot scans deduplicate canonical and legacy copies, and an
  ambiguous legacy bucket file can be claimed by only one verified identity.
- **Done:** account-scoped analytics now create a best-effort owner-only,
  versioned legacy baseline checkpoint before the first canonical history or
  bucket write. A
  later mixed-version legacy write is detected per identity and tier; both
  generations are preserved, affected display reads and writes fail closed,
  and routing retains only the last trusted account baseline or the pre-existing
  provider compatibility series for an unambiguous single-account snapshot.
  Conflict evaluation retains the post-pooling conservative envelope from both
  possible hourly cutoff sets for the affected identity while healthy identities
  keep the actual current-offset result, so evidence cannot age into a more
  optimistic relative route.
  Desktop Analytics and
  `doctor` surface affected tiers, while `stats --json` annotates bucket-tier
  conflicts on the rows that consume them, without exposing raw account or path
  data.
- **Done:** mixed-version incident inventory now survives an account leaving the
  current snapshot. Existing valid migration markers are upgraded under the
  identity evidence lock with explicit tier flags, a first-recorded timestamp,
  and a random stable incident reference. The default snapshot performs a
  bounded regular-file scan and reports `complete`, `partial`, or `suppressed`
  state plus truncation and unverifiable counts. It emits no unavailable
  account, digest, path, or recovery authority. Filtered snapshots inspect only
  visible identities, and current incidents include a safe provider-row index
  for exact automation joins. Desktop Analytics and `doctor` distinguish an
  unavailable account from a proven sign-out and never present a partial scan as
  a clean inventory.
- **Done:** a local-only `verify --recover-analytics` handoff now inspects one
  exact provider/account/tier without writing, then requires `--yes` before it
  moves only that tier's canonical and legacy files into a bounded owner-only
  evidence bundle. Inspection and confirmation recompute a strict merge plan
  from the selected tier's checkpoint and both retained branches. A proven raw
  plan installs and verifies the capped chronological multiset. A proven bucket
  plan installs and verifies the capped hourly aggregate union after subtracting
  the shared checkpoint once. Unprovable evidence admits an empty checkpoint.
  The receipt records fixed roles, byte counts, and SHA-256 digests without raw
  account or source paths. Exact merge manifests also record the installed row
  or bucket count, byte count, and digest.
  Recovery holds the canonical and lossy legacy lock domains together, refuses
  colliding legacy evidence that is not exclusively owned by the requested
  account, and returns the completed receipt on retry.
  Other identities, the unselected tier, provider-only compatibility analytics,
  quota evidence, credentials, preferences, profiles, leases, and alerts remain
  unchanged. Failures before checkpoint admission retain quarantine. A failure
  to finalize the manifest after admission returns
  `recovered_receipt_incomplete` with the retained evidence bundle and a nonzero
  exit. A late legacy writer re-triggers quarantine.
- **Done:** exact raw-history reconciliation uses the ordered checkpoint only
  when both retained branches have one unique suffix alignment, every row is
  valid trusted evidence for the exact identity, branch time is monotonic, and
  enough baseline remains to reconstruct the 200-row cap. Missing, malformed,
  ambiguous, or nonmonotonic evidence keeps the archive-and-reset plan.
- **Done:** exact aggregate-bucket reconciliation validates aligned, strictly
  ordered starts plus count, histogram, moment, exhausted-count, and extrema
  invariants. Each retained checkpoint branch must be a complete suffix whose
  additive fields cover the baseline. The merge computes canonical plus legacy
  minus the shared checkpoint once, preserves independently added buckets,
  applies the 90-day bucket cap, and verifies the installed digest. Missing,
  malformed, decreasing, duplicate, gapped, oversized, or ambiguously owned
  evidence keeps the archive-and-reset plan.
- **Remaining:** an opaque recovery target for an unavailable account. Do not
  make the random incident reference recovery authority until exact legacy
  ownership, collision behavior, and confirmation semantics can be proven
  without exposing or guessing the account identity. Reconnection and an exact
  current provider row remain required today.
- Pin every remaining supported response shape with sanitized fixtures.
- **Done:** Antigravity weekly-window semantics resolved from live evidence. The
  Cloud Code endpoint reports each model's single binding limit with no window
  type; quotabot surfaces the account's most-constrained one as a single weekly
  window with its true reset, rather than a reset-delta guess that mislabeled a
  near-term weekly as "5h". The separate burst limit and per-model-group
  breakdown are not exposed by this endpoint and stay in the per-model quotas.
- **Done:** prefer LM Studio's current `GET /api/v1/models` contract, preserving
  v0 and OpenAI-compatible fallbacks. Parse loaded instances, context, size,
  quantization, and capability evidence without loading or invoking a model.
- **Done:** parse Ollama's documented loaded `context_length`. Detect or
  conservatively exclude cloud-offloaded Ollama models from policies that promise
  local-only or free execution. Never estimate throughput by generating content.
- Grant implementation and deterministic expired-host-token fall-through
  fixtures are shipped for Claude and Codex. Remaining: validate the connected
  login flows on idle real-account machines. Claude now hashes current provider
  profile account and organization ids into a stable pool identity for cache,
  drift, leases, routing, and duplicate credentials. When profile identity is
  unavailable, a credential-generation identity is the fallback and multiple
  successful credentials fail closed to one routable pool.
- Keep the LiteLLM loopback, bearer-auth, and unauthenticated-denial regression
  green as its pinned dependency changes.
- Already shipped on 0.5.x: the normalized six-value `source_class` contract
  across every surface; deterministic provider-drift admission with stale
  last-trusted fallback and legacy-cache quarantine.

Acceptance: targeted parser, policy, schema, integration, and regression tests
pass; docs state the same source and spend semantics as the code; no ambiguous
runtime can satisfy a local-only budget.

### 0.7 - One forecast, one engine

**Outcome:** SEE, ROUTE, and ALERT are three views of a single pure object, and
that object can be replayed and simulated deterministically.

- **Shipped:** `decide(observations, now, context) -> Decision` in
  `collector/lib/decision.dart` is the single pure front door. It recomputes
  nothing - the routing core already produced the whole forward forecast, so
  `Decision.forecasts` (the ranked candidates, each carrying headroom, recent
  burn and its standard error, strand probability, confidence, and runway) is
  the SEE view, `Decision.recommended` is ROUTE, and `alertsBelow` is ALERT: one
  object, three views, pinned by test. `DecisionContext` bundles the bounded
  caller inputs so a decision is one recordable value. The MCP, HTTP, and CLI
  suggest surfaces now source from `decide` (behaviour-identical).
- **Shipped:** the forecast already carries honest uncertainty as first-class
  data - burn standard error, strand probability, and confidence per candidate -
  so a view renders a word or a dot without re-deriving it.
- **Shipped:** `replay(frames)` folds the pure core over recorded observation
  frames deterministically; the `--mock-provider` simulation (`simulateFleet`)
  drives the whole pipeline through `decide` with no network. Both pinned by test.
- **Shipped:** secondary route surfaces, including `top`, desktop, HTTP, and MCP,
  receive their recommendation from `decide`; the calibration ledger keeps its
  pinned replay of hourly history.
- No public contract change and no visible behavior change: existing SEE / ROUTE /
  `suggest` output stays stable, `decide().route` equals `suggestRoute()`.

Acceptance (met by the pure core, its tests, and routing surfaces):
the pure core has no I/O; SEE, ROUTE, and ALERT are all expressed as views of its
output; a recorded-history replay reproduces current decisions; the simulation
mode drives the full pipeline from fixtures with no network.

### 0.8 - The moat: a forecast that grades itself

**Outcome:** the number is not only shown, it is measured against what actually
happened, and it improves on the user's own data.

- **Shipped:** the calibration ledger replays the strand predictor over the
  hourly history quotabot already keeps, resolving each prediction against the
  outcome later buckets reveal (`calibration.dart`).
- **Shipped:** graded with proper scoring rules - Brier score, expected
  calibration error, and a reliability diagram (predicted probability versus
  observed frequency).
- **Shipped:** surfaced at the hood via `quotabot calibration` as "N%
  calibration agreement across M resolved forecasts", the reliability diagram,
  and per-provider lines. The agreement score is `1 - ECE`, not the percentage
  of individual forecasts that were correct. Casual percentage headlines are
  withheld until 40 forecasts resolve; machine output retains provisional scores
  with the exact sample count. The headline also appears in `quotabot doctor`.
- **Shipped (first parameter):** self-tuning selects the burn-lookback candidate
  on earlier history, leaves a forecast-horizon gap, and accepts it only when it
  improves Brier on the later 25 percent holdout using the same provider and
  timestamp pairs. Thin or non-improving evidence keeps the shipped default. It
  is advisory by default; `quotabot suggest
  --tuned-burn` opts in to applying the fitted lookback to the burn feeding the
  decision. The other free parameters (comfort threshold, risk z, lead time) are
  routing-policy values tuned by realized regret, not calibration; that evidence
  belongs to the post-1.0 [routing-evaluation corpus](#p1-grow-the-routing-evaluation-corpus).
- The plain-language layer generates every casual sentence from the calibrated
  number underneath, so "about an hour left" is always backed and inspectable one
  layer down.
- **Shipped:** reset-aware burn. The recent-burn regression now fits only the
  current draw-down run, segmenting at a refill (a large single-step headroom
  jump, a scheduled or redeemed reset) so a mid-window refill is never read as
  "recovering" and does not skew the runway. A rolling window's gradual give-back
  is well under the threshold and is not segmented. The observed availability
  history already records the post-reset capacity; this makes the burn and runway
  honest around
  it, and pairs with the spent-window escape-hatch detection in 0.9.

Acceptance: predictions and outcomes are logged and replayable; Brier and
reliability are computed and exposed only when observations suffice; a documented
metric shows the tuned parameters beat the shipped defaults on recorded history
without breaking a safety invariant; thin-data cases degrade to the defaults.

### 0.9 - The self-explanatory, opinionated advisor

**Outcome:** the simple surface is clearer because of the engine under it, and the
recommendation is aligned to what the user actually wants.

- **Done (shared explanation):** one plain human explanation shared by desktop,
  `doctor`, `suggest`, and `top`:
  winner, binding evidence, freshness and source, spend class, and fallback.
  The expanded desktop keeps an explicit no-safe-route answer when no winner is
  safe and exposes the explanation plus selectable decision id through a
  keyboard-accessible details control rather than hover alone.
  Compact mode pins the same next-route or no-safe-route answer, opens the same
  detail, and keeps overflow provider chips reachable in widget focus order.
  Replace unexplained glance phrases such as "thin data"; reserve strand
  probability, shrinkage, pipe discount, and cost weight for expanded or
  machine-readable detail.
- **Done (decision receipt):** one unified, low-cardinality
  `quotabot.receipt.v1` receipt across CLI, desktop, MCP, HTTP, and LiteLLM:
  deterministic decision id, snapshot source and age, binding pool, raw
  headroom, every adjustment, confidence reasons, lease and pipe-health effects,
  spend policy, winner qualification, and each rejected alternative's reason.
  Content-free and pinned by routing, schema, MCP, desktop, and LiteLLM tests.
- **Done (provider preference):** an explicit per-profile provider preference,
  applied among viable candidates only - it never revives an unavailable, spent,
  or spend-blocked route, and it shows in the reason ("first by your
  preference"). Persisted as `preference_order` in the profile and overridable
  per run with `suggest --prefer=a,b`; a pure `preferredViableCandidate` threaded
  through the decision core. A finer spend-order beyond provider preference
  (per-model or per-cost) remains open.
- **Done (local hardware fit):** reachable on-device models carry passive RAM
  and largest-single-GPU capacity evidence and a conservative `loaded`,
  `comfortable`, `tight`, `constrained`, or `unknown` fit. The model registry
  ranks that signal after loaded state, exposes the estimate and selected pool
  across CLI/MCP JSON, and explains it in plain model suggestions. Probes are
  bounded, cached, fail soft, and never load or invoke a model; fit remains
  advisory because runtimes may split memory.
- **Done (local capability gates):** local models now carry the capabilities
  their runtime declares, so a capability filter can select one. Ollama declares
  tool use, vision, and the model's maximum context per model; LM Studio
  declares them in both native model-list shapes; Lemonade declares context,
  labels, loaded state, and running context in its extended list and health
  shapes. Previously no local model
  declared anything, so every capability filter silently rejected all of them,
  including under `--budget=local`. An undeclared capability is still never
  assumed, so an OpenAI-compatible listing satisfies no capability filter. The
  Ollama read is bounded and cached by the runtime's content digest, stays
  metadata-only, and never loads or runs a model. The same evidence closed the
  matching defect in the other direction: a model a runtime declares as an
  embedding model stays listed for inspection but is no longer a routing
  candidate, because it cannot serve a generation request. An undeclared kind
  stays routable, since requiring a capability must fail closed while excluding
  a model must fail open.
- **Done (quota-stretch policy):** opt-in `quota_stretch` keeps fresh measured
  included quota while effective headroom is at or above a visible 25 percent
  reserve, then prefers a reachable on-device runtime. Callers can bound the
  reserve from 20 through 50 percent. The policy is shared by CLI, MCP, loopback
  HTTP, desktop profiles, and decision receipts; preserves `balanced` and
  `local_first`; rejects stale, drifted, manual, paid, and cloud-offloaded
  evidence; and prefers loaded local capacity before cold local capacity.
- **Done (multi-account):** provider accounts discovered on one machine can be
  shown together in one dashboard. Account-scoped profiles, cache, drift,
  history, and expansion state prevent work and personal evidence from being
  combined or visually confused.
- **Done:** Spent-window escape hatch. Codex's authoritative usage metadata
  carries `rate_limit_reset_credits.available_count` - the redeemable off-cycle
  full resets OpenAI calls banked resets - verified against a live account (not
  inferred). They are promotional resets, not cash or API credit. quotabot
  surfaces the stable count as an actionable line ("N banked resets available
  in Codex - redeem now") wherever provider details render, and `top` now shows provider details
  on a spent card too (previously dropped on the spent-collapse path), so a spent
  window shows the way out and not only a wait time. Detection and display only,
  no purchase action.
- Validate loading, empty, stale, auth, provider-drift, no-safe-route, alert, and
  integration states with first-time-user and operator checks.
- Already shipped on 0.5.x: the concise desktop route line with detail on hover,
  and the when-back emphasis on cards (a precise near-term countdown, an absolute
  day and time for a far reset).

Acceptance: a first-time user can answer the five recommendation questions in
definition-of-done item 4 from the default surface; the receipt is present and
low-cardinality on every listed surface; preference reorders only viable candidates
and is always explained; machine detail stays complete.

### 0.10 - Stabilize, polish, and prove recovery

**Outcome:** the existing product behaves predictably under ordinary use,
provider change, corrupt or stale local state, and clean installation. Users get
an actionable recovery path instead of a plausible-looking partial success.

- Keep corrective releases focused; develop the admitted local-model, native,
  and harness improvements in [Next](#next) as coherent additive increments.
- Resolve the complete confirmed post-0.9.9 defect inventory with focused
  regressions, starting with Claude authorization and credential lifecycle.
- Clear actionable dependency advisories from shipped and documented optional
  locks using reviewed first-party update branches.
- Make the supported source gates work from Windows paths containing spaces and
  keep contributor commands identical to the gates CI enforces.
- Run repeated evidence-driven bug hunts and quality-of-life passes across every
  existing surface. Prefer fewer, clearer states and bounded recovery guidance
  over new controls.
- Keep collection as overlapping metadata I/O on one worker isolate, with the
  desktop collect off the UI isolate. Do not turn quota reads into a
  per-provider isolate farm; the work is waiting on files and provider metadata,
  and extra isolates would drop the shared HTTP pool.
- **Done (repository signing readiness):** exact Windows PE and macOS Mach-O
  inventories, isolated signer jobs, platform-native verification, bounded
  receipts, credential-free packaging, and exact draft-asset re-verification are
  implemented for the CLI and desktop paths. Deterministic coverage is green;
  owner provisioning and successful protected rehearsals remain external gates.
- Activate and rehearse the implemented signing paths, then use one signed
  0.x candidate for the native install, update, rollback, provider, and
  accessibility evidence pass.

Acceptance: every applicable increment criterion in [Next](#next) passes. There is no
open reproducible correctness or credential-lifecycle defect, no unresolved
actionable dependency advisory in scope, all required CI is green from clean
main. Signing readiness is tracked independently until exact downloaded Windows
and macOS draft assets pass native signature verification for the 1.0 gate.

### 1.0 - Exceptional and rock-solid, then rehearse and cut

**Outcome:** the whole product is boring to install, verify, and update on every
claimed OS, and 1.0 is a version change rather than a discovery exercise.

- Complete native macOS and Linux records for naturally available providers and
  local runtimes; human cross-check live numbers against provider-owned views; keep
  simulated rare states separate from real-account evidence.
- Ship native prebuilt desktop bundles on every claimed OS with no Flutter SDK
  required for normal use, or explicitly narrow the 1.0 desktop promise to a labeled
  source-built preview (the prebuilt outcome is preferred). Confirm clean tray
  teardown on quit across all three OSes.
  **Done (portable artifact pipeline):** native Windows x64, macOS Apple Silicon,
  and Linux x64 archives now receive SHA-256 sidecars, archive-shape validation,
  native Windows/Linux readiness checks, build-provenance attestations, and a
  draft-release barrier. Clean native runners also re-download the draft assets
  and exercise side-by-side update, rollback, and data-preserving uninstall
  mechanics. Stable v0.10.2 supplies the current tagged acquisition, explicit
  GitHub Latest, bounded stable-channel discovery, self-update, and canonical
  unversioned install record.
  Signed platform-identity evidence and the same record on the exact 1.0 candidate
  remain required before this gate is closed. The credential-free Windows
  verifier covers an exact post-signing inventory, every shipped PE module,
  publisher identity, SHA-256 file digests, RFC 3161 timestamps, each token's
  SHA-256 message imprint and signature binding, and stable native verifier
  hashes. Its first-class receipt output atomically
  retains canonical success or bounded failure evidence with surface,
  architecture, allowlisted-stage context, and a comparison-only digest of all
  other receipt fields. That digest is not artifact identity, authentication,
  attestation, or independent workflow provenance. The SignTool timestamp
  ordering and fresh-download verification gaps are fixed. The repository path
  now replaces the exportable-PFX assumption with Azure Artifact Signing Public
  Trust, exact file catalogs, environment-bound GitHub OIDC, and durable
  subscriber EKU verification that does not pin daily leaf certificates. The
  macOS path inventories the standalone CLI, app, nested Mach-O modules, and
  native bundles; derives an exact inside-out signing plan; requires hardened
  runtime and a secure timestamp; bounds signing and stapling changes; binds the
  submitted archive, its freshly extracted inventory, code directories, and
  entitlements to accepted notarization; requires Gatekeeper to report a
  notarized Developer ID origin; and requires a valid staple on the app. The CLI
  cannot carry a stapled ticket, so its gate is bound accepted notarization plus
  native signature, entitlement, and Gatekeeper verification. Packaging and
  exact draft-asset verification run without Apple credentials.
  The explicit unsigned transition mode keeps 0.x product increments moving
  while disclosing that platform identity is absent. Owner eligibility, Azure
  resource and identity provisioning, the exact subscriber EKU, Apple Developer
  Program membership, Developer ID and notary credentials, protected rehearsals,
  workflow mode activation, and the signed rehearsal remain open.
- Complete the native accessibility smoke for widget, analytics, profiles, dialogs,
  tray, and terminal navigation: keyboard, focus, text scaling, contrast, reduced
  motion, and basic screen reader. Automated widget checks already enforce
  labels, 28 by 28 desktop targets, and contrast across expanded, compact, and
  Analytics surfaces in light, dark, and Hacker themes; do not treat them as
  native assistive-technology evidence.
- Run the three-OS clean install, previous-version upgrade, required-checksum,
  attestation, persistent-state, and source-setup matrix; exercise the
  inspect-before-run, update, data-preserving uninstall, destructive reset, and
  rollback paths, automating what can run safely on hosted clean machines.
  **Done for stable v0.10.2:** the published
  [release run](https://github.com/blisspixel/quotabot/actions/runs/33595583014)
  and unpinned GitHub Latest
  [install smoke](https://github.com/blisspixel/quotabot/actions/runs/33598880949)
  cover Windows, macOS, and Ubuntu, including stable-channel discovery, upgrade
  from stable v0.10.1, exact-tag self-update, persistent state, source setup,
  canonical Latest acquisition, and desktop-run checks. A live Windows path also
  updated from 0.10.2-rc.1 to stable. Repeat the full lifecycle on the signed
  0.x rehearsal and exact 1.0 candidate.
- Rehearse and cut: freeze the exact candidate from a clean main worktree; run all
  local and hosted gates; build the tag artifacts and verify checksums and
  attestations; install and smoke on clean native Windows, macOS, and Linux; repeat
  native provider, recommendation, accessibility, and operator-failure evidence on
  the frozen candidate; confirm notes, docs, version agreement, support path,
  rollback, and GitHub security status; cut 1.0 only when the run is boring and
  repeatable.

Acceptance: every definition-of-done item is met with dated evidence or an explicit
fixture / not-applicable reason; every artifact installs and starts on a clean
native host; update preserves a sentinel; uninstall leaves no broken PATH entry;
the candidate run is boring and repeatable.

## First 30 days after 1.0

Stabilization only:

- provider drift and quota-correctness fixes;
- install, update, launch, and uninstall fixes;
- crash, auth, cache, and integration diagnostics;
- accessibility regressions;
- documentation corrections and support-safe diagnostic guidance;
- additive compatibility fixes for the final MCP specification if it publishes
  after the 1.0 freeze.

No provider-count race, broad analytics expansion, or speculative architecture
work enters this window.

## Ranked outcomes after stabilization

### P1. Grow the routing-evaluation corpus

The engine and its legibility land pre-1.0: the pure forecast core and replay
harness in 0.7, the calibration ledger and oracle benchmark in 0.8, and the
unified decision receipt in 0.9. What remains after 1.0 is to keep growing the
offline conformance and replay corpus that measures policy invariants, stalls
avoided, quota stranded at reset, fallback use, and calibration honesty across
more recorded histories and provider shapes. Do not claim optimality. A
routing-math change must beat the current policy on a declared metric without
breaking a safety invariant.

The shipped minimum sample threshold and later holdout correct the immediate
presentation and in-sample selection defects. The next evaluation layer uses
rolling-origin validation so training always precedes evaluation, block-aware
uncertainty for overlapping horizons, and a versioned sanitized replay corpus.
Before changing the public score, compare the fixed-width ECE estimator with
equal-mass or debiased alternatives because common calibration-error estimators
can be biased. Relevant methods are summarized in
[Forecasting: Principles and Practice](https://otexts.com/fpp3/tscv.html) and
[Mitigating Bias in Calibration Error Estimation](https://proceedings.mlr.press/v151/roelofs22a.html).

### P1. Maintain explicit MCP revision compatibility

The [`2026-07-28` MCP specification was published on July 28](https://blog.modelcontextprotocol.io/posts/2026-07-28/).
The stateless core changes initialization, sessions, discovery, and request
metadata. quotabot currently implements `2025-11-25`; documentation must not
call that the latest revision or imply support for the new wire contract.

The harness work in [Next](#next) must verify legacy compatibility now and
prepare a dual-version matrix against supported Dart SDK and client releases.
Preserve existing clients while validating discovery, subscriptions, caching,
authorization, and JSON Schema on the new path. Trace metadata stays
content-free. Continue that matrix after stabilization whenever dependencies
or supported harness versions change.

### P1. Model quota as a typed shared pool

Before adding weighted coding plans, record pool scope, meter type, consumption
predictability, paid-continuation behavior, source authority, and policy
effective date. Cross-product and compute-weighted percentages must not be
presented as a linear number of future prompts. Write an ADR before changing the
windowing spine.

### P1. Harden multi-agent reservation behavior

Stress atomic cross-process reserve/release, idempotency, bounded TTL expiry,
crash cleanup, corrupt-ledger recovery, and decision visibility. Any reservation
weight is an explicit bounded caller policy because quotabot does not read the
task. Write an explicit state model for lease ownership, expiry, file replacement,
and recovery, then model-check its safety and liveness invariants before adding
more concurrency. High-level state specifications are useful here because they
test behaviors across implementations rather than restating one code path. See
[Specifying and Verifying Systems with TLA+](https://lamport.org/pubs/spec-and-verifying.pdf)
for the method, not as a claim that the current implementation has been verified.

### P1. Make failure boundaries observable and mutation-tested

Replace broad silent catches at authentication, filesystem, process, and provider
boundaries with a small typed failure taxonomy and bounded content-free
diagnostics. Preserve intentional fail-soft behavior, but make timeout, drift,
malformed evidence, cancellation, and unavailable dependencies distinguishable
in tests and support output. Add per-module coverage floors for critical boundary
packages so a high aggregate cannot hide thin adapters, then mutation-test the
pure decision, parsing, and recovery cores. Large-scale evidence suggests
mutation testing exposes test-suite holes that ordinary coverage misses; see
[Long-term Effects of Mutation Testing](https://research.google/pubs/long-term-effects-of-mutation-testing/).

### P1. Make local verification reproducible and bounded

Provide one documented local gate entry point that discovers or clearly rejects
the wrong Flutter, Dart, and Python versions, mirrors CI coverage and integration
commands, and emits a concise evidence summary. Split slow platform and
process-level tests into balanced shards with declared time budgets while keeping
the full three-OS matrix authoritative.

### P2. Decompose oversized modules behind stable seams

After behavior locks and boundary tests are in place, extract the desktop entry
point, cache and migration store, and MCP transport into bounded modules with
explicit ports. Move one seam per pull request and require contract-equivalent
tests, rather than attempting a high-risk rewrite or changing public schemas.

### P2. Expand distribution

After direct artifacts and update behavior are boring, add package-manager
channels in order of user demand and maintainability. Every channel must preserve
checksum/provenance verification, rollback, and cross-platform parity.

### P2. Add high-fit providers through an admission gate

GLM, MiniMax, Kimi, and Qwen are candidates, not commitments. A provider enters
implementation only when it passes all of these:

1. demonstrated user demand;
2. authoritative or clearly bounded quota metadata;
3. stable identity and authentication without cookie scraping;
4. zero-inference collection and explicit paid-continuation semantics;
5. a quota model representable without fabricated precision;
6. sanitized fixtures and deterministic malformed/drift cases;
7. a cross-platform discovery and verification plan;
8. fail-soft behavior and a named maintenance owner;
9. more routing value than the complexity it adds.

GLM remains the best researched first candidate because its official coding plan
publishes five-hour and weekly limits, but its time and model weighting means the
typed shared-pool work comes first.

Market review, 2026-07-18: candidate coding plans use provider-specific rolling,
weekly, or credit pools whose exact ratios and weights are time-sensitive.
[GLM consumption](https://docs.z.ai/devpack/faq) is model-weighted and
time-weighted, which is precisely why quota-as-a-typed-shared-pool must land
before GLM rather than after. [GitHub Copilot billing](https://docs.github.com/en/billing/concepts/product-billing/github-copilot-billing)
uses a monthly AI Credit pool with optional paid continuation, so if it is ever
added it is a credit-pool provider like Cursor, never an included-quota plan.
[Amazon Q Developer](https://aws.amazon.com/blogs/devops/amazon-q-developer-end-of-support-announcement/)
blocks new signups from 2026-05-15 and ends support for IDE plugins and paid
subscriptions on 2027-04-30 while other AWS experiences continue, so it does not
justify a separate adapter ahead of Kiro.

OpenRouter is a viable credit-backed metadata candidate, not an included-quota
plan. Its official [`GET /api/v1/key`](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key)
read works with the current API key and reports the key's optional dollar limit,
remaining-to-limit value, reset cadence, usage, expiration, and free-tier
classification. That value is a key spending control, not proof of funded
account credits.
The account-wide
[`GET /api/v1/credits`](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits)
read reports total purchased credits and usage but requires a broader management
key. Prefer the current-key read so quotabot does not ask for management authority
merely to show capacity. If admitted after the typed shared-pool work, classify
the route as `paid_api`, keep it out of default and `budget: quota` routing, show
dollars and reset semantics without calling them subscription quota, and fail
closed when either an explicit spending limit or funded-account proof is absent.
Sanitized fixtures must cover unlimited keys, free-tier keys, reset and non-reset
limits, expired or otherwise unusable keys, BYOK accounting, and malformed or
unauthorized responses. No inference request is needed to validate this surface.

ElevenLabs is a separate AI-service candidate, not a coding-route commitment.
Its official [subscription endpoint](https://elevenlabs.io/docs/api-reference/user/subscription/get)
exposes plan, credit use and limit, reset time, extension and overage metadata,
and voice-slot limits through
[restricted API keys](https://elevenlabs.io/docs/api-reference/authentication).
[Current pricing](https://elevenlabs.io/pricing) uses one shared credit pool whose
cost is weighted by product and model, with capped rollover. Its
[Pay As You Go](https://elevenlabs.io/docs/overview/administration/pay-as-you-go)
and legacy overage behavior also make exhaustion semantics account-dependent.
Evaluate it only after typed shared pools and an explicit product-domain
decision. If first admitted as a quota-only source, it must stay out of coding
recommendations, model routing, leases, and projected-waste policy until an
audio routing domain has comparable alternatives and explicit spend guardrails.

None of this changes the 1.0 scope; every candidate remains post-1.0,
admission-gated, and behind the typed shared-pool work.

## Product measures

quotabot has no telemetry. These are release and local evaluation measures, not
cloud collection:

- clean-install success and time to the first truthful `doctor` result;
- percentage of claimed source/OS cells with current evidence;
- route invariant pass rate over deterministic and replay corpora;
- recommendation explanation completeness across public surfaces;
- calibration error only when enough local observations exist;
- provider-drift detection and truthful degradation behavior;
- accessibility and keyboard smoke completion;
- support-safe diagnostic completeness without secrets or content.

## Deliberately deferred or rejected

- becoming a request proxy or hosted service;
- global leaderboards, account sync, or automatic telemetry;
- a general dollar-spend ledger (authoritative provider-returned paid fallback
  capacity remains an allowed, explicitly labeled roadmap input);
- provider breadth as a goal by itself;
- model quality rankings or task-content inspection;
- inference probes for latency or tokens per second;
- automatic paid API fallback or hidden overages;
- draft-only MCP behavior before a final specification and supported SDK path;
- decorative analytics without a routing, trust, or support outcome;
- opaque learned routing while a small auditable policy is sufficient.

The recurring product question is: does this make the available-capacity
decision truer, clearer, safer, or easier to act on? If not, it is not roadmap
work.
