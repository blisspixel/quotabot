# Model routing review - 2026-09-30

Accessed primary sources on 2026-09-30. This review used public documentation,
release notes, repository source, and papers. It made no inference requests,
read no host credentials or task content, and changed no dependency lockfiles.
Live upstream documentation can describe unreleased behavior; pinned source,
release tags, and executable integration tests determine supported behavior.

## Recommended boundary

Keep quotabot as a content-blind capacity and admission advisor. A caller can
first obtain eligible provider accounts and concrete models, then choose among
that set using its own explicit task requirements, session state, latency
measurements, or separately authorized semantic classifier. Revalidate the
selected account before remote dispatch through the existing atomic reservation
path. A classifier score never restores a denied, stale, drifted, spent,
unmapped, or unauthorized paid route.

The useful improvement is a reliable connection between advice and actual
dispatch. It does not require a learned quota router, new routing policy, or
inference in the collector. The three shipped policies remain `balanced`,
`local_first`, and opt-in `quota_stretch`. A caller's quality selection,
deployment scheduling, and session affinity are separate responsibilities.

## What the checkout already ships

| Surface | Verified behavior | Practical limit |
| --- | --- | --- |
| [decision.dart](../../collector/lib/decision.dart) and [ROUTING-MATH](../ROUTING-MATH.md) | Pure decision context, deterministic frame replay, risk-adjusted headroom, explicit policy, burn inputs, lease discount, admission gates, and fallback | Replay does not dispatch or estimate task difficulty. The mathematical analogies do not establish an optimality guarantee. |
| [registry.dart](../../collector/lib/registry.dart) | Explicit caller capability requirements, budget filters, conservative handling of missing required capabilities, concrete model availability, loaded/cold readiness, advisory host fit | A curated tier or declared capability is metadata, not empirical quality. Model recommendations and provider recommendations have different documented ordering. Host fit is not measured throughput. |
| [route_receipt.dart](../../collector/lib/route_receipt.dart) | Deterministic metadata-only provenance, policy, binding pool, evidence age, spend class, adjustment reasons, admission verdicts, and rejected alternatives | A receipt explains advice. It does not prove which deployment eventually ran or its account credentials. |
| [leases.dart](../../collector/lib/leases.dart) and [local_server.dart](../../collector/lib/local_server.dart) | Cross-process atomic target selection and reservation, bounded identifiers, scope-checked idempotency, trusted ledger-state handling, TTL and active-lease limits | A lease discounts local advisory headroom. It is not a provider reservation, semaphore, exact token estimate, or execution permission. HTTP targets identify provider/account rather than a concrete model. |
| [LiteLLM integration](../../integrations/litellm/README.md) | Managed logical-model rewrite, explicit spend declarations, quota-plan overage guard, authenticated loopback reservation, callback release, bounded metadata metrics, and local fallback | Configuration maps advice to deployments. The hook does not switch credentials, preflight a configured local fallback, or establish all downstream retry, streaming, and fallback contracts. |

Lease defaults are 120 seconds and a 15 percent headroom discount; the ledger
permits 15 to 3,600 seconds, 1 to 50 percent, and at most 256 active leases.
Acquisition waits at most five seconds. These are bounded caller reservations,
not inferred job sizes. The HTTP reservation handler timestamps the decision
after metadata collection, then selects while holding the ledger transaction.
The LiteLLM hook caches advisory `/suggest` reads but reserves the complete
eligible remote target set against fresh server evidence before dispatch.

[ROADMAP](../../ROADMAP.md) already distinguishes shipped calibration from
future evaluation. Brier score, expected calibration error, reliability bins,
and resolved-outcome counts exist. The public calibration-agreement headline
requires 40 resolved outcomes and is `1 - ECE`, not the probability that an
individual decision is correct. Tuned burn uses an earlier training segment,
a forecast-horizon gap, and a later holdout; broader rolling-origin and
block-aware uncertainty evaluation remains planned.

## Current upstream developments

### LiteLLM

The reviewed baseline pinned `litellm==1.92.2` in
[requirements.txt](../../integrations/litellm/requirements.txt). The
[primary release list](https://github.com/BerriAI/litellm/releases) marks
`v1.103.1`, published September 30, as the latest stable release. It separately
lists `v1.104.0-rc.2` and `v1.105.0-dev.1` as prereleases. The overview
[release-notes page](https://docs.litellm.ai/release_notes) still headlines
September 19's `v1.102.0`; it is not an authoritative latest-version check.
Do not treat live examples mentioning `v1.104.0` as stable checkout support.

The subsequent dependency review found the September 30
[critical proxy advisory](https://github.com/BerriAI/litellm/security/advisories/GHSA-7hp6-4w63-5g45),
which includes 1.92.2 in its affected range and lists 1.102.2 and 1.103.1 as
patched. The working tree selects 1.102.2 and regenerates the universal hashed
lock while retaining Python 3.10 through 3.13 and MCP v1. Primary
[1.102.2 package metadata](https://pypi.org/pypi/litellm/1.102.2/json) requires
`mcp>=1.28.1,<2`, while [1.103.1](https://pypi.org/pypi/litellm/1.103.1/json)
requires `mcp>=2.2.0,<3`. This is a compatibility reason to defer that major
dependency migration while applying the security fix. Installed proxy and routing tests must
verify this maintenance change; new beta router features remain separate work.

[Routing documentation](https://docs.litellm.ai/docs/routing) distinguishes
model-group selection from deployment selection. Deployment session affinity
narrows later requests to a pin scoped to a caller, model group, and session.
Its default 3,600-second TTL measures idle time and refreshes each turn. Redis
shares pins across proxy workers; without it pins are per instance. A pin on a
cooling or removed deployment falls through to healthy deployments. Complexity
router affinity instead pins its model choice. Quotabot has no equivalent
conversation pin, and a pin must not override new quota or admission denials.
RPM/TPM weights, least-busy counts, and latency observations are serving signals,
not subscription balance.

[Fallback documentation](https://docs.litellm.ai/docs/proxy/reliability) permits
ordered transitions between `model_name` groups after retries, plus separate
context-window, content-policy, default, and early-stream paths. A specific
model-id fallback skips cooldown checks. Current documentation describes
`disable_fallbacks` for ordinary and pre-first-chunk streaming fallback. These
behaviors require version-specific verification. Selecting a safe group at the
pre-call hook is insufficient if another reachable group or deployment has a
different account or spend class. Tests should induce an actual fake-backend
error; proxy mock-testing flags have been stripped since `v1.85.0`.

The newer [RoutingPlugin API](https://docs.litellm.ai/docs/routing_plugins)
can narrow `candidate_models`; an empty set aborts, and adding candidates cannot
expand the original pool. It is a plausible optional capacity gate after a
separately tested dependency update. The documented key is provider/model,
so exact deployment/account mapping still needs proof. Current complexity-router
composition disables session affinity with plugins and rejects
`adaptive=True` with plugins. Do not promise simultaneous adaptive learning,
session pinning, and a hard quota mask. This is an upstream capability candidate,
not a shipped quotabot adapter.

Current [beta Auto Routing](https://docs.litellm.ai/docs/proxy/auto_routing)
supports heuristics, lexical rules, semantic embeddings, LLM classification,
TypeSafe JEV, and custom classifier plugins. Heuristics still inspect request
content. JEV calls `/v1/systemone`, and its default classifier context includes
prior user turns. `test_routing` skips the selected completion but can still
spend classifier or embedding tokens. Custom classifier failure falls back;
mutating its candidate list does not impose a hard policy gate. Keep all such
classification in the caller, with separate authorization and accounting. A
returned choice probability is not independently measured correctness.

### RouteLLM

[RouteLLM's repository](https://github.com/lm-sys/RouteLLM) provides a
strong/weak model selector driven by prompt features and a calibrated
cost/quality threshold. Its stock matrix-factorization and similarity-weighted
ranking paths require OpenAI embeddings even when the completion models are
local. Other classifiers also perform inference. The
[local-model guide](https://github.com/lm-sys/RouteLLM/blob/main/examples/routing_to_local_models.md)
uses Ollama through LiteLLM; local completions do not establish a wholly local
classifier path. The [paper](https://arxiv.org/abs/2406.18665), submitted
June 26, 2024, evaluates preference-trained routing, not remaining subscription
quota. Its old example model pair and published savings do not establish
performance on September 2026 models or this user's workload. A prospective
caller adapter must mask unavailable choices, recalibrate its threshold on a
representative separately authorized dataset, and declare classifier cost and
execution location. No such adapter is shipped here.

### vLLM Semantic Router

The [project repository](https://github.com/vllm-project/semantic-router)
describes a programmable inference-routing layer using request signals,
preferences, and policies. Its release history identifies `v0.3` on June 5,
2026; live documentation also contains subsequent work. This is a separate
content-processing serving stack, not a replacement quota collector.
[Decision adaptation controls](https://vllm-sr.ai/docs/tutorials/learning/decision-adaptations/)
provide `bypass` for hard policy boundaries and `observe` before learned
adjustments affect traffic. A switch margin controls stability. Those are useful
caller patterns: apply hard account/spend/admission eligibility on every request,
then observe the semantic selector before granting it authority within the
remaining set. No vLLM Semantic Router integration or model-quality evaluation
is shipped in quotabot.

### New local decision models and native runtime routers

[Ollama v0.35.0](https://github.com/ollama/ollama/releases/tag/v0.35.0),
released September 28, introduces `/v1/systemone` with `choice`, `noul`, and
`score` questions. The example includes input and output token usage.
Nimble and Tev1 are supported decision models. This endpoint performs inference
even though it returns probabilities instead of prose. It belongs outside
quotabot's read path.

The [Nimble card](https://ollama.com/library/nimble) identifies a 9B decision
model and separates original-release held-out results from public-dataset
results. The [Tev1 card](https://ollama.com/library/tev1) describes 4B and 0.8B
variants, warns that its development evaluation mix was also used during model
development, and notes an approximately 2,000-token context. Those results do
not establish quality or calibration for quota decisions or coding-model choice.
Metadata discovery may represent installed decision models, but should not
infer general reasoning, tool use, vision, or coding quality from the existence
of SystemOne. No classifier, pull, warm-up, or benchmark is necessary to show
inventory and loaded/cold status.

[Lemonade's router validation API](https://lemonade-server.ai/docs/api/lemonade/#post-v1routingvalidate)
can run and load models for classifier, semantic-similarity, or LLM conditions.
It is unsuitable for metadata-only health checks despite skipping the final
completion. A `collection.router` can also combine local and cloud components;
execution location must account for every reachable component and classifier.
The dedicated local-runtime review tracks that parser issue and its fix criteria.

[llama.cpp v0.5.0 router documentation](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/server/README.md#routing-requests)
provides model status through `/models`. Per-model GET requests such as `/props`
can autoload by default; use explicit `autoload=false`. `/models?reload=1`
can unload or refresh live models. A future collector should read status without
reload or load operations. List presence, loading, sleeping, failed, and loaded
states must not collapse into an unconditional available flag. Local-runtime
coverage beyond the shipped providers remains a separately gated addition.

### Recent routing research worth using for evaluation design

[MetaRouter](https://arxiv.org/abs/2606.06178), submitted June 4, 2026,
studies implicit user cost/performance preferences using contextual bandits and
meta-learning. It requires interaction and task features, so it is not a
content-blind quota algorithm. Retain explicit user preferences here.
[BaRP](https://arxiv.org/abs/2510.07429), submitted October 8, 2025,
highlights the deployment restriction that only the chosen model's outcome is
observed. The applicable lesson is to avoid claiming unobserved alternatives
would have succeeded. Neither paper establishes this project's optimality,
quota freshness, admission, or concurrency safety.

## Ranked improvements and acceptance criteria

### 1. Make the leased account the actual dispatch account

The reviewed hook permits a provider-only deployment target. The server may
lease account B while that deployment still holds account A's configured
credentials. Exact-account candidates win when present, but a remaining
wildcard maps back to unchanged credentials. This is a concrete configuration
hazard, independently confirmed from source, not evidence that any live request
used the wrong account. A wildcard needs a documented single-account
assumption; ambiguous multi-account routing must require an exact binding.

Acceptance: a fake two-account provider cannot reserve B and dispatch A; exact
bindings select the matching deployment; an ambiguous wildcard fails closed or
uses an explicitly declared local fallback; an eligible single-account setup
remains compatible. Add an assertion that the selected concrete model's scoped
admission and capability gate agrees with its provider/account reservation.
Measured quota stays visible when that model is denied.

### 2. Close retry and fallback escape paths

Require every deployment and every reachable generic, default, context,
content-policy, order-based, and pre-output stream fallback to satisfy the
same account and spend declaration as the selected route, or disable those
paths for managed logical models until verified. Prefer a small proven contract
over duplicating the proxy's dispatcher. Keep caller session pins only while
they remain eligible; an account transition can also invalidate provider-side
conversation or encrypted-response state and must follow the harness contract.

Acceptance: run the installed pinned proxy against fake endpoints. Force a
429, 500, context error, content-policy error, and disconnect before first
output. A paid route never runs under the default policy, retries cannot move
to an unleased account, and metrics identify the deployment that actually
served the request. Repeat the matrix before any first-party LiteLLM update;
record stable versus prerelease support instead of relying on rolling docs.

### 3. Bound cancellation, freshness, and lease ownership

The Python hook uses `asyncio.to_thread` for HTTP. Canceling the coroutine does
not stop a dispatched thread, so a reserve can finish after its caller has
abandoned the request. Existing callback release and TTL are valuable recovery,
but cancellation, response loss, duplicate callbacks, and slow-drip responses
need explicit lifecycle tests. Socket inactivity timeouts and byte caps do not
by themselves prove a total wall-clock deadline. A remote route must also reject
a lease already expired when received; cache TTL is distinct from provider
evidence age and from lease lifetime.

Acceptance: use a fake clock and loopback service to cancel before reservation,
during reservation, after assignment, and during streaming completion. No
abandoned route dispatches; a lease that finished late is bounded by cleanup or
TTL; release remains idempotent; a retry with the same identity never changes
its account. Bound total metadata wall time even if bytes trickle continuously.
Reject expired leases, stale/drifted snapshots, future timestamps beyond a
declared skew allowance, and incompatible schemas. Log bounded metadata reasons
without content or exception bodies. Treat these as targeted verification gaps,
not claims that all current paths have failed.

### 4. Show execution readiness without generating work

Present evidence as runtime reachable, model known, loaded/cold, declared
on-device or upstream/cloud, admission, evidence timestamp/age, and advisory
hardware fit. A configured local fallback without a successful inventory read
should retain that weaker evidence. Distinguish model inventory from a proven
dispatch surface. Composite runtime routers must not become free/local evidence
because only their top-level alias looks local.

Acceptance: fixtures cover loaded, cold, loading, sleeping, failed, absent,
malformed, stale, nested cloud, upstream, missing component, and cyclic composite
evidence. No test invokes generation, SystemOne, embeddings, validation that
evaluates models, model pull/load/unload, or reload. Required capabilities remain
unknown when metadata does not declare them. All-local composition qualifies only
with bounded, complete evidence for reachable components; unresolved composition
stays inspectable without becoming a local or included-quota route.

### 5. Measure whether the current policies improve capacity outcomes

Extend the existing replay/calibration path before adding more scoring terms.
Measure quota denials or stalls, local fallback frequency, included quota
stranded at reset, advice latency, maximum active leases, and lease leakage
after TTL. Report effective sample counts, calibration bins, missing evidence,
and matched baseline definitions. Keep quality and user acceptance evaluation
in the caller; quotabot receipts must not collect prompts or model responses.

Acceptance: use deterministic event-driven fixtures with explicit workload
weights, shared pools, window resets, overlapping dispatches, outages, stale
evidence, and cancellations. Compare the same arrival sequence under the three
existing policies and a declared baseline, with invariant checks preceding
outcome comparisons. Use temporally separated evaluation and uncertainty by
reset period when sufficient history exists. Historical replay validates
decisions against observed evidence; it cannot manufacture the counterfactual
quota consumption of a policy that was never executed. Production shadow
inference, classifier benchmarks, and paid mirrored calls are not part of this
metadata-only evaluation.

## Documentation corrections and unresolved questions

- State that the bundled LiteLLM integration is a tested pre-call hook with
  a pinned version, not general support for every current beta routing API.
- Document exact account bindings for multi-account dispatch and distinguish
  the advisory receipt from observed deployment identity.
- Separate quotabot freshness, serving cooldown/retry-after, session idle TTL,
  and lease expiry. A cooldown is not a quota reset.
- Describe installed local decision models as inventory where supported.
  Neither a choice probability nor a provider tier is a quality guarantee.
- Keep RouteLLM, vLLM Semantic Router, native router composition, newer LiteLLM
  plugin integration, and additional runtime collectors labeled as research or
  proposed support until their metadata and dispatch contracts are tested.

This review did not benchmark classifiers, establish caller access to
interactive subscription surfaces, or verify a live deployment's account
mapping. It identified a source-level wildcard hazard and concrete test gaps.
The narrow corrections should precede new router adapters or scoring policies.
