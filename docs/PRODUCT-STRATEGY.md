# Product strategy

Updated 2026-07-10. Revisit this document when provider quota models, the MCP
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
explicit state, not an empty card.

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

The CLI already has a low-friction release path. The desktop is visually a
first-class product but still requires a Flutter source build. The product must
either ship a verified prebuilt desktop path or stop presenting desktop as a
normal end-user 1.0 surface. Update, uninstall, data preservation, destructive
reset, and rollback must be separate documented operations.

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
- Binding-window correctness, staleness, source scope, spend classes, capability
  gates, and local fallback are represented in machine contracts.
- The desktop and terminal surfaces are visually mature for a 0.x utility.
- The core is deterministic and heavily tested, with dedicated verification,
  schema, security, drift, and release gates.
- The advisor-not-proxy and zero-inference boundaries are meaningful product
  differences, not only marketing language.

### Friction now

- The default recommendation line exposes phrases such as "thin data" and the
  terminal exposes "strand" before teaching their meaning.
- Advanced routing choices are documented across long command lists instead of
  one intent matrix.
- The README leads with a desktop product that normal users cannot install from
  a prebuilt desktop artifact.
- Trust copy sometimes says read-only or never leaves the machine even though
  bounded local writes, provider metadata calls, Antigravity account onboarding,
  and explicitly enabled external webhooks exist.
- The canonical roadmap had accumulated shipped history and speculative
  provider detail, obscuring the few remaining release gates.
- LM Studio's native API and Ollama's cloud-offload behavior have evolved beyond
  the assumptions in the current adapters.

### Too much relative to current need

- More analytics visualizations before first-run and recommendation clarity.
- Provider count without a strict admission and maintenance test.
- More routing mathematics without an offline outcome and invariant benchmark.
- Spend-ledger depth that weakens the included-quota focus.

## Current external evidence

Research was refreshed on 2026-07-10. External material is evidence, not product
policy.

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
capabilities. That is a direct metadata-only path to more honest readiness than
the current v0-first adapter.

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

1. Unify routing provenance as one decision receipt.
2. Build deterministic conformance, replay, and calibration evaluation.
3. Adopt the next final MCP revision through a dual-version test matrix.
4. Harden multi-agent leases under concurrent and corrupt-state stress.

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
