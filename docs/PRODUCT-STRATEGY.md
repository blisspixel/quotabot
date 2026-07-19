# Product strategy

Updated 2026-07-18. Revisit this document when provider quota models, the MCP
specification, or the product's acquisition path changes materially. The
execution order lives in [ROADMAP.md](../ROADMAP.md).

## Decision summary

quotabot should be the most trustworthy local answer to two questions:

1. What included AI coding capacity is actually usable now?
2. Where should this request go next, and why?

The monitor is useful, but monitoring alone is crowded. The durable product is a
content-blind capacity decision system that combines subscription windows,
local-runtime readiness, source provenance, fail-soft behavior, and concurrent
agent reservations without becoming a proxy.

The immediate constraint is not feature depth. It is proving the existing
surface across native hosts, making the recommendation easy to understand,
closing current provider and runtime drift, and making desktop acquisition as
credible as the visual product promise.

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

The CLI has a low-friction release path, and the desktop now has a native
portable-archive pipeline with checksums, attestations, and a draft-release
barrier. Clean native runners now exercise install, update, rollback, and data
preservation before publication. That mechanism still has to pass on each exact
release candidate before it becomes published evidence. The remaining 1.0
acquisition work is operating-system signing and notarization. Update,
uninstall, data preservation, destructive reset, and rollback remain separate
documented operations.

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
- The advisor-not-proxy and zero-inference boundaries are meaningful product
  differences, not only marketing language.

### Friction now

- Advanced routing choices are documented across long command lists instead of
  one intent matrix.
- Portable desktop assets are not yet Authenticode-signed, Developer ID-signed,
  or notarized, which remains the largest acquisition gap for a first-class 1.0
  release.
- Native keyboard and screen-reader evidence is still incomplete even though
  automated focus, scaling, contrast, and semantics coverage is strong.
- Claude and Codex grants still need dated idle-machine validation against real
  accounts. Claude credential generations now fail closed and cannot share
  cache or drift evidence, but the usage endpoint still provides no
  provider-backed identity for durable account labels or deduplication.
- The canonical roadmap had accumulated shipped history and speculative
  provider detail, obscuring the few remaining release gates.

### Too much relative to current need

- More analytics visualizations before first-run and recommendation clarity.
- Provider count without a strict admission and maintenance test.
- More routing mathematics without an offline outcome and invariant benchmark.
- Spend-ledger depth that weakens the included-quota focus.

## Current external evidence

Research was refreshed through 2026-07-18. External material is evidence, not
product policy.

### Included-model entitlements can change faster than quota shapes

Anthropic announced that beginning July 20, 2026, Fable 5 is included for Max
and Team Premium at 50% of limits. Pro and Team Standard retain access through
usage credits and receive a one-time $100 credit.

Source: [Anthropic's July 17 Fable plan
announcement](https://x.com/claudeai/status/2078302415804379218).

The product implication is to keep entitlement policy separate from measured
capacity. Fable carries no calendar cutoff or hardcoded 50% balance in quotabot.
It becomes quota-backed only when the current provider response contains a
scoped Fable pool and same-response provider metadata confirms a Max or Team
Premium entitlement at or after the July 20, 2026 UTC policy boundary. A host
credential's plan label is diagnostic context, not
current included or credit-backed entitlement proof. Pro, Team Standard,
host-label-only, and plan-unknown
rows stay visible under the unrestricted budget without being called included
quota. The scoped pool gates Fable without blocking unrelated Claude models. A
dated plan announcement can
classify expected inclusion, but it cannot prove what remains in an account now.

### MCP is about to change substantially

The MCP 2026-07-28 release candidate removes protocol sessions and the
initialize handshake, adds discovery and cache semantics, formalizes extensions,
hardens authorization, and moves tool schemas to full JSON Schema 2020-12. The
project states that the final specification is planned for 2026-07-28 and that
the release is breaking. quotabot should preserve current-final compatibility,
prepare a boundary and test matrix, and implement only after the final spec and
supported Dart path exist.

Source: [MCP 2026-07-28 release candidate, published 2026-05-21](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/).

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
length, and expiry. Ollama also offers cloud models that are invoked through the
local daemon but executed by Ollama's cloud service. A `budget=local` promise
therefore needs execution-location evidence, not only a loopback URL.

Sources: [Ollama running-model API, accessed 2026-07-10](https://docs.ollama.com/api/ps),
[Ollama cloud models, accessed 2026-07-10](https://docs.ollama.com/cloud).

LM Studio's current native `GET /api/v1/models` response exposes installed
models, loaded instances, context, parallel capacity, size, quantization, and
capabilities. quotabot reads that endpoint first, with the older native and
OpenAI-compatible shapes as fallbacks, for direct metadata-only readiness.

quotabot now combines that runtime size/readiness evidence with a passive,
bounded host-memory read. Loaded state remains direct evidence; cold models get
an advisory comfortable, tight, constrained, or unknown fit against system RAM
and the largest supported GPU pool. This improves local-first ordering without
entering the request path or making a throughput claim. The remaining local
quality gap is capability propagation and native evidence across diverse GPU and
unified-memory hosts, not another synthetic benchmark.

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

## Strategic sequence

### Now: earn 1.0

1. Close current source, provider-drift, local-runtime, and integration trust
   gaps.
2. Complete native verification and end-user acquisition evidence.
3. Make the default recommendation self-explanatory and complete accessibility
   smoke checks.
4. Rehearse the exact tag and cut only after clean-host artifact verification.

### Next: prove decision quality

1. Grow deterministic conformance, replay, and calibration evaluation around
   the now-shared decision receipt.
2. Adopt the next final MCP revision through a dual-version test matrix.
3. Harden multi-agent leases under concurrent and corrupt-state stress.

### Later: expand only through evidence

1. Add typed shared-pool semantics through an ADR.
2. Admit one high-fit provider, likely GLM, only after the rubric passes.
3. Expand package-manager distribution after direct artifacts are boring.
4. Add analytics or operator exports only when they change a decision or reduce
   support cost.

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
