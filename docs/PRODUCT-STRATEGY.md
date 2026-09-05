# Product strategy

Updated 2026-09-04. Revisit this document when provider quota models, the MCP
specification, or the product's acquisition path changes materially. The
execution order and single immediate priority live in
[ROADMAP.md](../ROADMAP.md#next); this document explains the product reasoning
and does not maintain a second work queue.

## Decision summary

quotabot should be the most trustworthy local answer to two questions:

1. What included AI coding capacity is actually usable now?
2. Where should this request go next, and why?

The monitor is useful, but monitoring alone is crowded. The durable product is a
content-blind capacity decision system that combines subscription windows,
local-runtime readiness, source provenance, fail-soft behavior, and concurrent
agent reservations without becoming a proxy.

The next product gains come from making existing evidence useful in everyday
work: inspectable local-model choices, dependable native behavior, and explicit
connections to the agent harnesses people use. Stable 0.10.3 already improves
loaded-model, context, residency, and host-pressure summaries. Per-model detail,
capability truth, connection diagnostics, and versioned harness support can now
build on that foundation without broadening default paid routing.

Release signing remains a trust requirement for 1.0. Both signing paths are
implemented; owner identities and successful protected rehearsals remain open.
Those external dependencies do not freeze local-model, platform, or integration
improvements. Continue coherent 0.x releases, preserve unsigned disclosures,
and repeat final native evidence against the eventual signed artifacts.

## User jobs

### Glance

"Can I keep working here, and when does the binding limit reset?"

The answer must fit in one glance. It includes the binding window, remaining
capacity, reset, freshness, and any scope caveat. It does not require the user to
understand the routing formula.

### Decide

"What should I use next?"

The answer names one safe route, a plain reason, the budget policy, and a
fallback. Capability and spend constraints are eligibility gates before ranking.

### Verify

"Why should I trust this number or recommendation?"

The answer exposes the source class, age, binding pool, confidence reductions,
adjustments, and rejected alternatives without exposing credentials or user
content.

### Operate

"Will my agents coordinate safely, and can I diagnose failure?"

The answer includes cache-only decisions, reservations, explicit expiry,
structured errors, alert delivery state, and support-safe diagnostics.

## Product surface roles

| Surface | Primary role | Default depth |
|---|---|---|
| Desktop widget | glance and next action | plain human answer |
| `doctor` | first success and repair | actionable evidence |
| `top` | live terminal operation | compact power-user view |
| `suggest` and `models` | scripts and direct agent use | stable human and JSON contracts |
| MCP | agent-native quota, routing, and reservations | structured contracts and resources |
| Plain loopback HTTP | minimal integration fallback | small local JSON surface |
| LiteLLM plugin | optional execution handoff | policy-enforced consumer of quotabot advice |
| Analytics, report, calibration | inspect and learn | optional depth, never first-run clutter |

No surface gets its own routing semantics. They are presentations or consumers
of one normalized evidence and decision core.

## What exceptional means here

### Truth before breadth

Every number has a source class, scope, capture time, and failure mode. A missing
truthful value is better than a precise-looking guess. Provider drift becomes an
explicit diagnostic over stale last-trusted evidence when that evidence exists,
not an empty card or a routable precise-looking value. A legacy cache with no
provable trusted baseline is quarantined with null headroom. Drift clears only
after clean recovery evidence.

### One understandable recommendation

The default explanation answers five questions:

1. What should I use?
2. Why did it win?
3. How fresh and authoritative is the evidence?
4. Can this choice create metered spend?
5. What happens if the route fails?

Terms such as strand probability, shrinkage, pipe discount, cost weight, and
lease discount belong in expanded or machine detail. The simple layer must be
truer because the deeper layer exists, not harder to read.

### Boring acquisition and recovery

The CLI has a low-friction release path, and the desktop has a native
portable-archive pipeline with checksums, attestations, and a draft-release
barrier. Stable v0.10.2 completes the exact release, explicit GitHub Latest,
bounded stable-channel discovery, self-update, and three-OS install path; the
[baseline release evidence](BUILDING.md#baseline-release-evidence) records what it
proved. The earlier rc.12 and rc.17 lifecycle checks remain supporting
acquisition evidence. That evidence is not a substitute for the signed rehearsal
or for rerunning the complete path on the exact 1.0 candidate. The repository signing
implementation is complete; owner identities, protected rehearsals, mode
activation, and signed lifecycle evidence remain. Update, uninstall, data
preservation, destructive reset, and rollback remain separate documented
operations.

### Content-blind auditability

Decision and diagnostic records contain quota metadata, routing factors, and
bounded identifiers only. They never contain prompts, source, responses,
credential values, or exception messages. External delivery is explicit and
previewable.

### Conservative autonomy

Parallel agents can reserve local quota capacity with idempotent, expiring
leases. A failed ledger, stale snapshot, or unavailable quotabot never silently
turns into paid API spend.

## Current surface assessment

### Strong now

- The SEE and ROUTE thesis is coherent across desktop, CLI, MCP, HTTP, and
  LiteLLM.
- Routing surfaces share one content-blind decision receipt and one complete
  human explanation.
- Binding-window correctness, staleness, source scope, spend classes, capability
  gates, and local fallback are represented in machine contracts.
- The desktop and terminal surfaces are visually mature for a 0.x utility.
- The core is deterministic and heavily tested, with dedicated verification,
  schema, security, drift, and release gates.
- Stable v0.10.2 completes the exact release, GitHub Latest, bounded
  stable-channel discovery, self-update, and three-OS published-installer
  rehearsal, so release mechanics have current
  evidence rather than only a future plan.
- The repository implements isolated, fail-closed Windows and macOS signing
  paths around immutable candidate handoffs.
- The advisor-not-proxy and zero-inference boundaries are meaningful product
  differences, not only marketing language.

### Friction now

- Per-model fit and capability evidence is richer in the registry than in the
  desktop and terminal detail surfaces. Unknown context, authentication, and
  execution location need clearer explanations before adding more charts.
- Named harnesses have different MCP, CLI, selection, and sandbox contracts.
  A generic MCP example does not establish a working model handoff or prove
  that a subscription is usable through another harness.
- Published portable assets remain unsigned even though both repository signing
  paths are implemented. Owner identities, successful protected rehearsals, mode
  activation, and a signed fresh-download lifecycle remain the largest
  acquisition gap for a first-class 1.0 release.
- Native keyboard and screen-reader evidence is still incomplete even though
  automated focus, scaling, contrast, and semantics coverage is strong.
- Claude and Codex grants still need dated idle-machine validation against real
  accounts. Claude credential generations now fail closed and cannot share
  cache or drift evidence, but the usage endpoint still provides no
  provider-backed identity for durable account labels or deduplication.
- Calibration now withholds thin-sample headlines and validates a fitted
  lookback on later history, but it still needs rolling-origin evaluation,
  block-aware uncertainty, and a broader sanitized replay corpus before any
  optimality claim would be defensible.

### Too much relative to current need

- Charts that cannot answer a local readiness, capacity, or recovery question.
- Provider count without a strict admission and maintenance test.
- More routing mathematics without an offline outcome and invariant benchmark.
- Spend-ledger depth that weakens the included-quota focus.

## Current external evidence

Research was refreshed through 2026-09-02. External material is evidence, not
product policy.

### Included-model entitlements can change faster than quota shapes

Anthropic's current plan guide says that beginning July 20, 2026, Fable 5 and
Fable 5.1 use up to 50% of the regular shared weekly limit for Max, Team
Premium, and premium legacy seat-based Enterprise. Pro, Team Standard,
Enterprise Standard, and usage-based Enterprise use pay-as-you-go credits.

Source: [Anthropic's current Fable plan
guide](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).

The product implication is to keep entitlement policy separate from measured
capacity. Fable carries no calendar cutoff or hardcoded 50% balance in quotabot.
It becomes quota-backed only when the current provider response contains a
scoped Fable pool and current provider usage or profile metadata read with the
same credential confirms a supported exact entitlement at or after the July
20, 2026 UTC policy boundary. Max and Team Premium are supported today. Generic
Enterprise remains fail-closed until provider metadata distinguishes premium
from standard. A host
credential's plan label is diagnostic context, not
current included or credit-backed entitlement proof. Pro, Team Standard,
host-label-only, and plan-unknown
rows stay visible under the unrestricted budget without being called included
quota. The scoped pool gates Fable without blocking unrelated Claude models. A
dated plan announcement can
classify expected inclusion, but it cannot prove what remains in an account now.

### MCP now requires an explicit revision compatibility plan

The final MCP `2026-07-28` revision was published on July 28. Its stateless core
replaces the initialization handshake and transport sessions, with new discovery,
request metadata, caching, and authorization behavior. quotabot still implements
the `2025-11-25` contract. Preserve that working path and verify each named
harness's legacy compatibility while preparing a tested dual-version migration
against supported Dart and client SDKs. Publication of a standard alone is not
evidence that the installed server implements it.

Source: [MCP 2026-07-28 final release, checked 2026-09-04](https://blog.modelcontextprotocol.io/posts/2026-07-28/).

MCP tool annotations affect client approval and retry behavior. Current MCP
guidance treats `readOnlyHint` as a signal that a client may skip confirmation,
`idempotentHint` as a retry signal, and `openWorldHint` as a trust-boundary
signal. quotabot's live collection tools therefore must remain conservatively
annotated: collection can refresh cache, history, and OAuth state, and
Antigravity may perform provider-required onboarding. Cache-only does not itself
prove read-only behavior either: `decide_now` can compact expired records while
reading the local lease ledger.

Source: [MCP tool annotations guidance, published 2026-03-16](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/).

### Local-runtime metadata is richer, but local is no longer synonymous with free

Ollama's passive `GET /api/ps` response includes loaded models, VRAM, context
length, and expiry. Ollama and Lemonade can also expose cloud models through a
local daemon while executing remotely. A `budget=local` promise therefore needs
execution-location evidence, not only a loopback URL.

Sources: [Ollama running-model API, accessed 2026-07-10](https://docs.ollama.com/api/ps),
[Ollama cloud models, accessed 2026-07-10](https://docs.ollama.com/cloud),
[Lemonade model-list API, accessed 2026-07-27](https://lemonade-server.ai/docs/api/openai/#get-v1models).

LM Studio's current native `GET /api/v1/models` response exposes installed
models, loaded instances, context, parallel capacity, size, quantization, and
capabilities. quotabot reads that endpoint first, with the older native and
OpenAI-compatible shapes as fallbacks, for direct metadata-only readiness.

quotabot now combines that runtime size/readiness evidence with a passive,
bounded host-memory read. Loaded state remains direct evidence; cold models get
an advisory comfortable, tight, constrained, or unknown fit against system RAM
and the largest supported GPU pool. This improves local-first ordering without
entering the request path or making a throughput claim. Capability propagation
shipped in v0.9.4, and the explicit quota-stretch policy shipped in v0.9.6.
Native evidence across diverse GPU and unified-memory hosts follows; another
synthetic benchmark does not.

Source: [LM Studio model-list API, accessed 2026-07-10](https://lmstudio.ai/docs/developer/rest/list).

### New coding plans require typed quota semantics

Z.ai documents five-hour and weekly GLM Coding Plan limits, while advanced
models consume quota at different peak and off-peak multipliers. A flat remaining
percentage cannot truthfully imply a linear number of future prompts. Weighted
providers should wait for typed pool scope, meter, weighting, and paid-
continuation semantics.

Source: [Z.ai Coding Plan FAQ, accessed 2026-07-10](https://docs.z.ai/devpack/faq).

### Monitoring breadth and diagnostics are crowded

Current monitoring tools already compete on provider breadth, local history,
notifications, dashboards, reports, and diagnostics. For example, current
CodexBar releases include redacted diagnostics, provider hardening, multi-
provider fixes, and operator polish. These are useful market signals, but they
make raw provider count a weak product strategy.

Source: [CodexBar releases, accessed 2026-07-10](https://github.com/steipete/CodexBar/releases).

The implication is an inference from the landscape: quotabot should compete on
decision quality, subscription semantics, local-runtime truth, reservations,
and content-blind integration contracts.

## Strategy behind the roadmap order

The [roadmap Next section](../ROADMAP.md#next) owns the exact execution order.
The September research is linked from that section and records current source
evidence, versions, and uncertainty. The rationale for the order is:

### Immediate product priority: useful local-model choices

A person with several installed models should be able to inspect what is loaded,
what capabilities are known, whether a context requirement is met, and why a
model fits or is excluded. The existing registry already contains much of this
evidence. Exposing it through one shared presentation seam improves the desktop,
terminal, and eventual harness setup without inventing a second routing policy.

Truthful hardware and execution scope come first. Windows compatibility counters
can misstate modern VRAM, unified memory cannot be counted twice, and a runtime
listening on localhost may route elsewhere. The
[local-model research](research/2026-09-local-models.md) and
[platform research](research/2026-09-platform-quality.md) identify the concrete
source and test requirements. Native recovery and accessibility work can proceed
before signing and be revalidated on the final artifacts.

### Then connect that evidence to actual harness workflows

Start with versioned advisory setup, then explicit local model selection through
a documented harness API. Detection, advisory connectivity, target mapping,
availability, and applied model selection are distinct states. The
[harness review](research/2026-09-harnesses.md) records differences among
OpenClaw, OpenCode, pi, Hermes, and NemoClaw, including unsupported sandbox
topologies and diagnostics that can make inference calls. Support requires
reproducible metadata-only tests, not a universal integration badge.

The first near-future runtime candidate is a bounded llama.cpp metadata profile
because multiple harnesses now offer that local workflow. Runtime admission,
passive insight, and automatic routing remain independently validated changes.

### Independent acquisition priority: sign the release artifacts

Windows executables are not Authenticode-signed, and the macOS app is not
Developer ID-signed or notarized. A correct recommendation engine still fails
its first-run promise if platform trust controls warn about or refuse its
download.

Apple's current direct-distribution guidance makes Developer ID signing a
prerequisite for notarization and calls for hardened runtime, a secure
timestamp, notarization, and ticket stapling. Microsoft's current Authenticode
guidance identifies signing and timestamping as the authenticity and integrity
path for downloaded executables and recommends RFC 3161 with SHA-256 for new
signatures. These platform signatures complement the checksums and restricted
GitHub build-provenance attestations already shipped; they do not replace them.

Sources: [Apple notarization guidance, accessed 2026-07-27](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Microsoft Authenticode timestamping guidance, accessed 2026-07-27](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures),
[GitHub artifact attestation guidance, accessed 2026-07-27](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

Signing comes before the final native release evidence because it changes the
exact artifacts and platform launch path under test. Earlier clean-install,
accessibility, provider, and lifecycle work still improves the product; repeat
the required checks after signing. Repository work establishes immutable candidate handoffs, isolated
signer jobs, fail-closed platform verification, bounded receipts,
credential-free packaging, and final digest-bound fresh-download checks.
Credential-free macOS CI also exercises real Apple signing tools with hardened
ad hoc fixtures. A Windows signing identity, Apple Developer Program membership,
Developer ID identity, protected release credentials, and successful native
rehearsals still require project-owner authority.

### After signed-artifact rehearsal: close the remaining 1.0 evidence gates

The remaining gates are native macOS and Linux provider records, dated Claude
and Codex idle-machine grant validation, native accessibility smoke, and the
final exact-candidate rehearsal. v0.9.9 proves the tag, artifact, checksum,
provenance, and lifecycle foundation. Stable v0.10.2 adds explicit GitHub Latest,
bounded stable-channel discovery, self-update, and canonical unversioned
acquisition coverage, but all evidence
must be repeated against the frozen, signed 1.0 candidate.

### After 1.0 stabilization: improve decision evidence

Grow deterministic conformance, rolling-origin replay, calibration uncertainty,
and mutation evaluation around the shared decision receipt; maintain the MCP
dual-version compatibility matrix; and harden multi-agent leases
under an explicit state model plus concurrent and corrupt-state stress. Typed
shared-pool semantics, admission-gated providers, package-manager distribution,
and additional exports remain later work and enter only when they pass the
decision filter below.

## Decision filter

Score a proposed item before roadmap admission:

| Question | Weight |
|---|---:|
| Does it improve correctness or prevent an unsafe route? | 5 |
| Does it reduce first-run or support friction? | 4 |
| Does it make a recommendation easier to understand or verify? | 4 |
| Does it strengthen cross-platform evidence? | 3 |
| Does it improve agent reliability without entering the request path? | 3 |
| Is the source stable, testable, and maintainable? | 3 |
| Does it preserve zero inference, content blindness, and no-surprise spend? | required |

Reject any item that fails the required boundary. Prefer the smaller item when
scores are close. Provider demand and maintenance cost must be explicit rather
than assumed.

## Claims discipline

- Say what the current evidence proves, including date and scope.
- Use "reduces" rather than "prevents" for failures outside quotabot's control.
- Call a route local only when execution location supports that claim.
- Do not call a heuristic optimal without assumptions, derivation, and an
  outcome benchmark.
- Do not call the whole product read-only. Name the bounded local writes and the
  exact operation that performs them.
- Do not claim market uniqueness. State verifiable product behavior and let the
  combination differentiate itself.
