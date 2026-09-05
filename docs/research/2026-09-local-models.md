# Local model product research

Reviewed 2026-09-04 against `main` at `2e283956` and stable 0.10.3.
External research cost: $0. Sources below are current primary documentation;
they are evidence of an API contract, not proof of a successful native runtime
test. Future work is a proposal, not shipped support.

The strongest next local improvement is an inspectable model view built from
evidence already collected. People should be able to see which installed model
is ready, why it fits, what the runtime actually declares, and what is unknown.
This can ship through the existing direct-release pipeline while publisher
identity procurement continues independently.

## What 0.10.3 already does

- Ollama, LM Studio, and Lemonade inventory and loaded-state reads are shipped.
  Ollama adds digest-cached, bounded model capability reads. LM Studio prefers
  native v1, then v0, then compatible model listing. Lemonade folds health into
  model inventory. All avoid model execution.
- Local summaries already lead with a loaded model, running context, and
  runtime-reported GPU residency. More loaded models and disk inventory follow.
  The desktop correctly says `loaded`, without claiming active computation.
- The registry already supports declared tools and vision, context filtering,
  loaded-before-cold selection, embedding exclusion, and advisory memory fit.
  `hardware_fit` has `loaded`, `comfortable`, `tight`, `constrained`, and
  `unknown` states and exposes the selected memory pool and observation time.
- Host RAM is read on Windows, macOS, and Linux. NVIDIA memory and utilization
  are supported where `nvidia-smi` exists. Windows adds a bounded GPU fallback.
  Host evidence stays distinct from model residency and quota history.
- Ollama cloud naming and Lemonade cloud recipe/provider evidence are excluded
  from local and quota budgets. Non-loopback runtime origins cannot prove local
  execution.

Implementation: [local adapters](../../collector/lib/adapters/),
[hardware probes](../../collector/lib/local_hardware.dart),
[registry](../../collector/lib/registry.dart),
[desktop local row](../../app/lib/main.dart), and
[terminal local row](../../collector/lib/top.dart).

## Ranked delivery slices

### 1. Make every local model inspectable

**Value:** `+2 more loaded` should lead to the actual models, and a cold model's
fit should be understandable without reading JSON. The current desktop
`_localRow` and terminal `_localRows` render only the provider headline and
detail strings. They do not show per-model registry fit or capability evidence.

Add a keyboard-accessible Models detail control to each local provider. Show
loaded models first, then cold models using the registry's existing ordering.
Each row has model identity, residency, quantization, observed context, tools,
vision, and a plain fit explanation. Separate cloud-offloaded and embedding
entries and explain their exclusion. Keep unavailable or stale entries visible
as last observed. Show the selected host memory pool once with its timestamp;
avoid repeating host utilization as if it belonged to each model. Small windows
need a bounded scrollable detail view rather than expanding the tray endlessly.
Give `top` the same evidence through its selected-provider detail interaction.

**Schema:** none required for the first release. Reuse `ModelInfo`, `ModelEntry`,
and `LocalModelHardwareFit` through a small pure presentation helper. Display
`context_tokens` as observed context until slice 2 records its basis.

**Acceptance:** widget and terminal tests cover two loaded models, cold fit,
unknown capabilities, stale evidence, embedding and cloud exclusions, long
identifiers, narrow layouts, keyboard focus, and text scaling. Test that opening
details makes no new network call. Update synthetic demo captures. Do not add a
second ranking implementation or imply a model quality benchmark.

### 2. Preserve useful capability and context distinctions

[LM Studio's native model list](https://lmstudio.ai/docs/developer/rest/list)
reports reasoning configuration, model maximum context, and a list of loaded
instances with separate configurations. The current parser ignores reasoning,
uses only the first instance, and collapses maximum and configured context.
Ollama separately publishes [running context](https://docs.ollama.com/api/ps)
and [model metadata](https://docs.ollama.com/api-reference/show-model-details).
Its [context guidance](https://docs.ollama.com/context-length) confirms that
increasing context changes memory demand. A model's advertised ceiling is
therefore insufficient evidence for a loaded instance's usable context.

The smallest correctness patch is to carry declared local reasoning into the
existing `ModelInfo.reasoning` field. Today
`meetsRequirements` rejects all locally parsed models for `require_reasoning`
because no local adapter fills that field. Admit explicit supported reasoning
options; malformed, absent, or off-only declarations remain unknown or absent.
Do not infer reasoning from a model name. Add other runtime declarations only
after their exact metadata field is verified.

Then add optional `max_context_tokens`, `configured_context_tokens`, and a
bounded `loaded_instances` list with instance id and configured context. Keep
the legacy `context_tokens` field compatible. Instance selection must be
explicit or conservative when instances differ; do not silently take the
largest context as the guarantee for an arbitrary dispatch.

**Acceptance:** parser-to-registry tests show a declared local reasoning model
passing the requirement, absent and malformed evidence failing it, a 4k loaded
instance failing a 32k requirement despite a 128k model maximum, and mixed
instances remaining deterministic. Pin additive cache/JSON/MCP round trips.
UI copy should distinguish `Configured 4k` from `Model maximum 128k`.

Files: [LM Studio parser](../../collector/lib/adapters/lmstudio.dart),
[shared normalization](../../collector/lib/adapters/ollama.dart),
[model schema](../../collector/lib/models.dart),
[registry](../../collector/lib/registry.dart), and
[parser tests](../../collector/test/local_runtime_parse_test.dart).

### 3. Make local connection and execution evidence honest

[LM Studio authentication](https://lmstudio.ai/docs/developer/core/authentication)
can require bearer tokens. The adapter currently sends none and treats every
non-200 response as a fallback opportunity, ending with `not running`. Add
explicit user-supplied token configuration and bounded `auth_required`,
`auth_failed`, `timeout`, `unsupported_api`, and `malformed_metadata` results.
Provide a repair step without changing LM Studio settings. Preserve model
inventory if only optional loaded-state detail fails; display unknown loaded
state instead of claiming no model is loaded.

Execution location needs a separate compatibility audit. [LM Link's REST API
guidance](https://lmstudio.ai/docs/developer/core/lmlink) explicitly says a
localhost request may execute on a preferred remote device. All current
LM Studio model parsers set `cloud: false`; localhost alone cannot substantiate
this-machine memory fit in that configuration. [Lemonade cloud
offload](https://lemonade-server.ai/docs/guide/configuration/cloud/) also shares
one catalog with local execution.

**Schema proposal:** distinguish transport origin from optional
`execution_location: on_device | remote_device | cloud | unknown` and include a
bounded evidence basis. Preserve known cloud exclusions. Establish documented
location evidence before admitting ambiguous multi-device entries to local
budgets or attaching this machine's hardware fit. A global forced downgrade is
not justified without checking actual versioned metadata and compatibility.

**Acceptance:** fixtures cover 401/403, timeouts, failed optional detail,
loopback redirects, remote preference, cloud-only inventory, and mixed local
and offloaded models. Credentials never reach output, diagnostics, redirects,
or unrelated origins. Local and quota routing must not broaden on ambiguity.
This is a compatibility and trust slice, not permission to scrape private state.
The [platform review](2026-09-platform-quality.md) covers the related WSL case:
the process answering localhost and the collector's observed memory pool may
belong to different execution environments.

### 4. Extend hardware insight where a supported source exists

Keep the existing fit heuristic advisory. It currently estimates model storage
plus bounded overhead and chooses the best individual memory pool; it is not a
context-aware allocation model. Do not sum shared RAM and unified GPU memory or
promise throughput from that estimate.

[Lemonade's documented system endpoints](https://lemonade-server.ai/docs/api/lemonade/)
offer host resource readings, devices, backend lifecycle states, and storage
capacity. An optional bounded read can explain `backend installed`,
`backend update required`, or `acceleration unavailable` on a user's existing
runtime. Its supported-platform page includes [Windows, Linux, and
macOS](https://lemonade-server.ai/docs/guide/install/), so native fixtures and
field evidence should replace old platform assumptions.

**Schema:** additive metric records with `source`, `scope`, `observed_at`,
unit, value, and explicit absence reason. Distinguish unified memory, discrete
VRAM, model residency, and host load. Keep samples ephemeral and display-only.
Use device/backend enums and bounded names, dropping storage paths, raw error
text, OEM identifiers, and API-key metadata that the display does not need.

**Acceptance:** native Windows, Apple Silicon, and Linux evidence for each
claimed metric; unsupported hardware and permission failures stay unknown.
Test impossible numeric values, missing units, oversized responses, sample
expiry, shared-memory double counting, and collection deadlines. The first
native expansion should target one evidence gap, such as AMD device/backend
visibility through an already running Lemonade server. NPU utilization remains
conditional on a supported counter, not inferred from NPU presence.
Before broadening probes, address the existing Windows GPU capacity and device
scope limitations identified in the [platform review](2026-09-platform-quality.md).

### 5. Admit additional runtimes through explicit metadata profiles

Implement one adapter at a time. [llama.cpp's server
contract](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
has health, model, and optional metrics surfaces. Its property and slot payloads
also contain prompt-template or request-related material, so they need a
content-boundary review before any collector reads them. Begin with bounded
health/model metadata and an explicit configured runtime identity. Do not treat
every service on port 8080 as llama.cpp.

[MLX LM](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md)
documents a compatible model list but it does not prove loaded readiness or
capabilities. Inventory-only inspection is a defensible first profile.
[vLLM's stable metrics](https://docs.vllm.ai/en/stable/usage/metrics/)
include running and waiting request gauges and KV-cache occupancy. Those can
support an optional display such as `2 running, 3 waiting`, using allowlisted
aggregate metrics and bounded labels. They do not establish a completion-time
prediction or a per-model quality score.

**Schema and acceptance:** reuse the model/evidence additions above; add no
provider quota windows. Cover runtime identity, 503 loading, disabled metrics,
counter resets, mixed models, stale samples, auth, and remote/offloaded
execution. Prove refreshes never load, wake, download, unload, benchmark, or
invoke models. Validate each exact upstream release shape before claiming it.
Runtime support and queue-aware routing are separate deliverables; routing
changes require offline policy evaluation after passive display is proven.

## Delivery order and decision rule

Start with slice 1 and the small reasoning regression from slice 2. Triage the
execution-location issue before expanding any local-only claim. Follow with
context provenance, connection diagnostics, and one native hardware gap. New
runtime profiles come after these shared seams prevent repeated mistakes.

Every implementation slice should update the usage/data-source docs with exact
support and limits, pass static analysis, maintain at least 90 percent collector
and 80 percent desktop line coverage, and pass the complete required CI matrix
before entering a release. Capture
metadata-only fixtures and dated native evidence separately. No paid service,
model download, benchmark, store enrollment, or identity purchase is needed
for this plan.

## 2026-09-05 follow-up: execution-location evidence

This follow-up narrows slice 3 into the next proposed correctness increment.
The execution-location schema and routing changes below are future work, not
features implemented in 0.11.0. The historical 0.10.3 baseline above remains
unchanged.

[LM Link](https://lmstudio.ai/docs/developer/core/lmlink) permits localhost
requests to execute on a preferred remote device. The reviewed
[native REST model list](https://lmstudio.ai/docs/developer/rest/list) exposes
loaded instances but no documented execution-device discriminator. A model's
local copy, loaded flag, or loopback endpoint cannot establish where its routing
identifier will execute.

There is a concrete future source: the SDK's
[ModelInfoBase at fe095ac4](https://github.com/lmstudio-ai/lmstudio-js/blob/fe095ac4e8960e846950ea44707617f1b6ad4c23/packages/lms-shared-types/src/ModelInfoBase.ts)
defines `deviceIdentifier` as explicit null for a model local to that server,
or a string for a remote LM Link device. Missing is not null. This is not a
documented REST field. Using it requires binding the configured endpoint and
exact dispatch identifier; a runtime host behind WSL, a container, or a tunnel
is not automatically the collector's execution environment.

Do not automatically add `lms link status --json` to passive collection. Its
[status implementation](https://github.com/lmstudio-ai/lms/blob/ff5080941a878f9283dee990e8252e4461d3d361/src/subcommands/link/status.ts)
uses a [client creation path](https://github.com/lmstudio-ai/lms/blob/ff5080941a878f9283dee990e8252e4461d3d361/src/createClient.ts)
that can start llmster and read or refetch CLI credentials. The underlying
[LM Link status types](https://github.com/lmstudio-ai/lmstudio-js/blob/fe095ac4e8960e846950ea44707617f1b6ad4c23/packages/lms-shared-types/src/repository/LMLink.ts)
are also marked unstable and discouraged for public adoption. A separately
admitted source must be bounded, metadata-only, authenticated safely, and unable
to wake or modify the runtime.

**Proposed contract:** add `execution_location: on_device | remote | unknown`
and `execution_location_basis` (`runtime_metadata`, `cloud_route`, `not_reported`,
`conflicting_evidence`, or `legacy_snapshot`) to `ModelInfo`. Reuse the enclosing
observation time. Preserve `local` as integration identity and `cloud_offloaded` as an
independent exclusion. Known cloud routes become remote; private remote devices
are not automatically paid or free. Missing, malformed, conflicting, and legacy
local-only evidence stays unknown. Return no device identifiers or names.

One shared positive-evidence predicate should govern model budgets, provider
availability, local-first and quota-stretch fallback, readiness ranking, cached
decisions, and host hardware fit. Remote and unknown models remain inspectable
under `budget: any`; they cannot satisfy local/free capacity promises. Desktop
and terminal views should explain the exclusion while preserving runtime loaded
state separately. Regression fixtures must cover all LM Studio REST shapes,
explicit SDK null versus missing, mixed devices and inventories, stale/cache
round trips, cloud conflicts, and existing embedding/manual/paid exclusions.
Spy clients must prove no new probes or runtime commands occur.

The schema is additive, but eligibility intentionally tightens. When this
correction ships, on-device LM Studio models may lose automatic
local/quota fallback until a supported positive source is admitted. Keep the
caller's original choice when no safe route exists. Audit positive Ollama and
Lemonade producers before claiming their fallback is preserved; an absent cloud
flag must not silently turn unknown into on-device evidence.

### Follow-up: explicit upstream configuration

Static review of Ollama v0.33.3 confirms that cloud-name suffixes are an
incomplete exclusion. Its [wire types](https://github.com/ollama/ollama/blob/b79067b0db7417f20108363bc22adb97f35c966a/api/types.go#L737)
and [inventory producer](https://github.com/ollama/ollama/blob/b79067b0db7417f20108363bc22adb97f35c966a/server/model_list_cache.go#L322)
carry `remote_host` and `remote_model`. Aliases can therefore name an upstream
route without containing `-cloud`. Private upstreams are supported: the
[dispatch test](https://github.com/ollama/ollama/blob/b79067b0db7417f20108363bc22adb97f35c966a/server/routes_generate_test.go#L673)
configures a private HTTP server and permits it through `OLLAMA_REMOTES`.
That test was inspected, not executed.

The bounded correction preserves declared or unresolved upstream configuration
as an independent exclusion from local-only and included-quota advice. It must
not label every private server as public cloud, paid, or free. Malformed,
partial, or conflicting declarations remain excluded. Raw upstream addresses
and model names are unnecessary for the public exclusion reason.

This correction adds negative evidence. It does not turn missing declarations
into positive collector-local execution proof. The shared scope resolver above
remains necessary, particularly for tunnels, WSL, LM Link, and composite
Lemonade recipes. No additional probe or inference call is needed to preserve
the upstream fields already present in inventory metadata.
