# Local runtime status and routing evidence review

Reviewed 2026-09-30 against stable 0.11.6 and the working tree based on
`9da66069b450fd8c4278924c53ac058249dc5b78`. Primary documentation and tagged
upstream source were read on that date. This review made no inference request,
downloaded no model, and did not start or change a runtime. Public documentation
and source establish contracts; they do not establish successful native runtime
validation. [ROADMAP.md](../../ROADMAP.md#next) remains the execution queue.

The most useful immediate work is better evidence about the models already
visible: text-generation eligibility, actual usable context, exact dispatch
identity, connection health, and execution scope. Additional runtime names are
less useful until those distinctions survive collection, cache, routing, and
display consistently.

## Reviewed versions and existing support

| Runtime | Release evidence checked | Shipped quotabot reads and limits |
|---|---|---|
| Ollama | [v0.35.0](https://github.com/ollama/ollama/releases/tag/v0.35.0), published 2026-09-28; v0.35.1 was a pre-release | Tags, loaded inventory, digest-cached bounded show metadata; explicit thinking, tools and vision; loaded context and GPU residency; cloud and upstream exclusions |
| LM Studio | [0.4.25](https://lmstudio.ai/changelog/lmstudio), released 2026-09-19 | Native v1 model list, then v0 and compatible fallbacks; first loaded instance, context, size, quantization, tools and vision; reasoning withheld pending scope |
| Lemonade | [v2026.39.1](https://github.com/lemonade-sdk/lemonade/releases/tag/v2026.39.1), published 2026-09-23 | Extended model list plus optional health; context, tool/vision labels, loaded state, top-level cloud exclusions |
| llama.cpp | [v0.5.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0), published 2026-09-23 | No built-in adapter; source contract reviewed for a future bounded profile |
| MLX LM | [v0.31.3](https://github.com/ml-explore/mlx-lm/releases/tag/v0.31.3), published 2026-04-22 | No built-in adapter; names-only compatible discovery is a possible future profile |

GitHub versions above are the non-prerelease releases returned by the upstream
latest-release endpoint on the review date, rather than guarantees about every
nightly build. LM Studio 0.4.24 also fixed its Loaded Instances UI context display;
0.4.25 added Splash support on compatible Apple Silicon. Backend/engine version
and application version should remain separate. See the
[LM Studio changelog](https://lmstudio.ai/changelog/lmstudio).

Source and tests confirm that per-model desktop inspection, terminal `m`
inspection, loaded-before-cold ranking, advisory hardware fit, and Ollama
reasoning are already implemented. The older
[2026-09 local-model review](2026-09-local-models.md) describes its historical
0.10.3 baseline. Its original assertion that every local reasoning requirement
fails does not describe 0.11.6. No benchmark or quality ranking was performed.

## Concrete corrections implemented in the working tree

Lemonade's tagged [model-label contract](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/docs/api/openai.md#model-labels)
distinguishes text chat from embedding, reranking, image, transcription, speech,
audio generation, classification, and 3D deployments. It accepts singular
`embedding` and `classifier` aliases. Before this change, quotabot only excluded
the plural `embeddings` label. A downloaded image or speech model could therefore
become a text-generation recommendation or a provider fallback.

The working tree adds optional `text_generation` boolean evidence. Explicit
false excludes a model from generation recommendations and provider fallback
while retaining inventory inspection. It does not mislabel an image model as an
embedding model. Explicit `chat` is true; absent or older characteristic-only
labels remain unknown. Malformed arrays and conflicting deployment declarations
cannot become capacity. Negative loaded-type evidence is preserved when list
and health observations disagree. The optional field survives sanitation,
snapshot/cache serialization, registry output, and schema validation; older
snapshots remain compatible. Desktop and terminal details explain the exclusion.

The same tagged [model-list contract](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/docs/api/openai.md#get-v1models)
defines `context_length` separately from `max_context_window`. quotabot now
prefers a valid current/configured `context_length`; a valid loaded health
`ctx_size` still wins. A declared 4k context cannot qualify a 32k requirement
merely because the model maximum is 128k. A present invalid `context_length`,
including null, remains unknown; only its absence permits legacy maximum
fallback. The stable serializer emits this field only for a positive value,
and does not document null as an unloaded-state signal.

These are implemented, unreleased corrections. Focused verification passed
252 collector tests, including parser, registry, provider fallback, cache,
schema, and terminal regressions; 24 existing model-detail widget tests passed;
collector analysis reported no issues. The final full gate and coverage report
belong to the overall change. No live Lemonade account or native fixture capture
was performed during this review.

## Ollama: richer list metadata and separate cloud spend

The v0.35.0 [list producer](https://github.com/ollama/ollama/blob/v0.35.0/server/model_list.go)
now populates `capabilities` from the same model capability resolver used for
execution. It also fills model maximum context in `details.context_length`.
The [wire types](https://github.com/ollama/ollama/blob/v0.35.0/api/types.go)
confirm that tags can carry capabilities and upstream fields. quotabot still
ignores the new list capability/context fields and says that neither model-list
endpoint declares capabilities. That statement needs versioned qualification.
This is a metadata opportunity, not a requirement to expand automatic probes.

Use valid tags declarations first, preserving the current digest identity and
negative upstream evidence. Retain bounded show fallback for older servers and
missing fields. Declared absence and unknown evidence must stay distinct. A
newer list result can reduce unresolved capability entries when a library exceeds
the 48-model show cap, without making additional per-model calls. Do not infer
capabilities from model names or promote a malformed list.

[Running inventory](https://docs.ollama.com/api/ps) provides residency, running
context, and expiration; it does not provide a busy/streaming counter. GPU-resident
bytes are not utilization. Current [context guidance](https://docs.ollama.com/context-length)
describes VRAM-dependent defaults and increased memory demand at larger context.
The FAQ still mentions a blanket 4096-token default. Prefer observed running
context and dated version evidence over either generic default when routing.

The [show response type](https://github.com/ollama/ollama/blob/v0.35.0/api/types.go#L738)
can bundle templates, system text, messages, and model-file information. Keep
normalization limited to admitted metadata, never persist or log raw responses,
and consider whether richer tags can remove unnecessary show reads. No show
field is permission to examine conversation or custom prompt content.

[Current cloud pricing](https://ollama.com/pricing) describes monthly included
usage credits: Pro $60, Max $300, and Team $1,000 shared, with separately purchased
credits. Included balances refresh on the subscription-start day and do not
roll over. The provider explicitly says switching an existing Pro/Max plan to
the new plan removes its old session and weekly limits. Existing and switched
accounts must therefore not share an assumed meter. Plan prices and a reachable
cloud catalog establish neither measured remaining balance nor authorization
to spend purchased credits. No supported zero-token remaining-balance endpoint
was found in the reviewed public daemon contract.

The [cloud guide](https://docs.ollama.com/cloud) distinguishes downloaded local
models from cloud names and documents retirement notices in usage settings.
Preserve `:cloud`, `-cloud`, and explicit upstream exclusions. A private upstream
is not necessarily public cloud, paid, or free. Missing upstream fields still
do not prove that a localhost endpoint executes in the collector's environment.

The [v0.35.0 release](https://github.com/ollama/ollama/releases/tag/v0.35.0)
introduces decision models through `/v1/systemone`. It returns choices,
probabilities, or scores and reports token usage. That endpoint is inference,
including when used for model routing. quotabot must not invoke it for quota
reads, capability checks, or automatic task classification.

## LM Studio: instance identity and connection health

The [native v1 list](https://lmstudio.ai/docs/developer/rest/list) exposes a model
key, multiple loaded instance identifiers, instance configurations, maximum
context, quantization variants, and reasoning options. The existing parser takes
the first instance, discards its dispatch identifier, and falls back to model
maximum when configured context is missing. This can overstate a loaded route's
usable context, and a model key does not describe every loaded instance equally.
Preserve maximum and configured context separately, and select an exact instance
or a conservative bound rather than the largest or first value silently.

[LM Link](https://lmstudio.ai/docs/developer/core/lmlink) can send a localhost
request to a preferred remote device. The documented native REST list still
does not expose a per-model execution-device field. Runtime loaded state is not
proof of collector-local execution, and this machine's hardware fit is not the
remote device's fit. The earlier SDK `deviceIdentifier` investigation remains
a potential, separately admitted source; absence must not be interpreted as
explicit local evidence. Do not add an auto-starting CLI command to passive
collection merely to obtain that field.

[Authentication](https://lmstudio.ai/docs/developer/core/authentication) can
require a user-configured API token. Today, quotabot sends none and retries
fallback model endpoints after every non-200 response before reporting
`not running`. Distinguish unsupported API from reachable-but-auth-required,
auth-failed, timeout, and malformed metadata. Add tokens only through explicit
quotabot-owned configuration bound to the exact validated origin. Never copy
host credentials to output or follow an unchecked redirect with them.

## Lemonade: composites and useful passive status

The stable [serializer](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/src/cpp/server/server.cpp#L3168)
embeds component model objects for collections, including `collection.router`.
The [official hybrid example](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/examples/router/policy_cloud.json)
combines a local chat component with a cloud target. A top-level recipe other
than `cloud` is therefore insufficient on-device evidence. Current quotabot
checks only top-level cloud fields and ignores components. A future scope
resolver should apply every component's exclusion monotonically and leave
missing, conflicting, cyclic, or unsupported composition unknown. Raw routing
policies can contain prompt conditions and classifier prompts; normalized scope
needs bounded component evidence, not those policies or task text.

The [stable API reference](https://github.com/lemonade-sdk/lemonade/blob/v2026.39.1/docs/api/lemonade.md)
offers loaded type/device/pinned/busy/streaming evidence, version, backend
lifecycle state, host resource readings, and root-level Prometheus metrics.
Useful next display: server connected, backend installed/update required,
model loaded, model busy, and model streaming as separate observations.
Busy can include maintenance. `last_use` includes loading and is not proof of
current computation. Host CPU/GPU/NPU activity remains host-scoped; unavailable
values remain unknown. Reject raw paths, process arguments, OEM/BIOS details,
provider addresses, and API-key metadata from the normalized display.

The same reference documents `/v1/routing/validate` as potentially loading and
running classifiers. Do not treat it as a safe quota/status probe. Optional
health failure also must not become `no model loaded`; today it becomes an empty
loaded list. Use explicit unknown load state when its evidence source fails.

## Additional runtime profiles

The tagged [llama.cpp server contract](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/server/README.md)
supports passive health and inventory. Router `/models` distinguishes unloaded,
loading, loaded, sleeping, downloading, and failed states. `reload=1` can unload
changed running models, and model-specific GET forwarding can auto-load by
default. A future collector must omit reload and use `autoload=false` where
applicable. Sleeping must not receive loaded readiness. `/props` and `/slots`
contain prompt/template or request fields, so they require a separate content
boundary review. Training context from model metadata is not configured per-slot
context. Begin with explicit runtime identity, health, and bounded model status;
do not discover arbitrary services by port or use request probes.

[MLX LM's tagged server guide](https://github.com/ml-explore/mlx-lm/blob/v0.31.3/mlx_lm/SERVER.md#list-models)
documents compatible model listing with identifiers and creation times. It does
not establish loaded readiness, execution scope, tool support, or configured
context. An explicit inventory-only profile is defensible. Apple Silicon engine
support inside Ollama or LM Studio should remain an engine detail unless a
separate server is actually configured. Generic OpenAI compatibility cannot
fill missing runtime metadata automatically.

## Current models worth compatibility fixtures

Use real installed-runtime metadata as the route source. The following public
catalogs motivate fixture coverage, without recommending a download or ranking
quality:

| Family | Verified public evidence on 2026-09-30 | Compatibility implication |
|---|---|---|
| [Qwen3.8](https://ollama.com/library/qwen3.8) | 27B entries, MLX variant, advertised tools/vision/thinking and 256k maximum | Keep format and digest identity; advertised maximum and default thinking do not establish active context or effective reasoning settings |
| [Gemma 4](https://ollama.com/library/gemma4) | Multiple sizes and dense/MoE variants, GGUF/MLX entries, 128k/256k maxima, local and cloud tags | Do not collapse active parameter count into memory size; test local and cloud variants sharing a family name |
| [Qwen3-Coder-Next](https://ollama.com/library/qwen3-coder-next) | Dedicated coding family with multiple quantizations | A coding name or upstream benchmark is not a local capability declaration or machine-fit observation |
| [Muse Glimmer](https://lmstudio.ai/blog/muse-glimmer) | LM Studio announces local support for Meta's 30B agentic model | Exercise native reasoning/tool metadata, loaded-instance identity and variants rather than adding an unsourced local quality tier |

Quantization, backend, context, parallelism, KV-cache configuration, multimodal
components, and speculative drafters can change memory demand. The shipped
file-size-plus-overhead fit remains advisory; neither a sparse active parameter
count nor a benchmark should replace observed residency or validated capacity.

## Ranked recommendations and acceptance evidence

1. **Complete deployment correctness.** The implemented non-text correction
   should pass the full project gate and retain inventory visibility. Extend
   fixtures when another runtime explicitly declares non-chat deployment kinds.
   Prove suggestions under every budget and provider fallbacks exclude them,
   including mixed inventories, singular aliases, malformed declarations,
   sanitation, old-cache compatibility, and display reasons.
2. **Resolve execution scope before stronger local claims.** Cover Ollama
   upstreams, LM Link, WSL/tunnels, and Lemonade collections in one shared rule.
   Fixtures must include mixed local/cloud children, missing children, cycles,
   conflicts and redirects. Unknown evidence cannot acquire local readiness,
   collector-host fit, or local/quota eligibility through a different surface.
3. **Preserve context and dispatch identity.** Add maximum/configured context
   provenance and exact loaded-instance evidence. A 4k running instance must
   fail a 32k requirement despite a 128k maximum; mixed instances must be order
   independent. Reject invalid numbers and keep unknown active context unknown.
4. **Use richer Ollama metadata without extra probing.** Pin current tags
   capabilities and maximum-context fixtures plus older-server fallbacks.
   Bound library size and bytes. Test repulled digests, list/show disagreement,
   capability arrays, explicit non-text kinds, and no retention of raw content.
5. **Make status failures actionable.** Preserve reachable, auth-required,
   unsupported API, timeout, and malformed metadata as distinct diagnoses.
   Optional detail failures must not fabricate cold or idle state. Add only
   versioned passive busy/streaming/backend metrics with source, scope,
   observation time and expiry; never attribute shared host load to a model.
6. **Admit one new runtime profile after those seams.** llama.cpp health and
   router inventory are the strongest next source. Spy tests must prove no
   auto-load, wake, reload, unload, download, inference, prompt read, or mutation.
   MLX inventory can follow with explicit unknown metadata. Queue-aware policy
   changes require offline evaluation after display evidence is reliable.

These recommendations refine the existing roadmap rather than create another
execution queue. Native Windows, Linux, Apple Silicon and remote-device captures
remain necessary for each claimed hardware or execution-scope producer. Public
source review, mocked contract tests, native validation, and the release gate
are separate evidence.
