# Harness interoperability research, September 2026

Reviewed 2026-09-04 against quotabot `main` at `2e283956`, version 0.10.3.
External spend: $0. This report uses official documentation, source, and release
metadata. No harness inference, account login, host configuration change, or
sandbox mutation was performed. Upstream documentation describes possibilities;
it is not evidence that quotabot has tested those integrations.

## Recommended direction

Make quotabot easy to consult from the tools people already use, then make its
recommendation easy to apply explicitly. Start with a small, versioned advisory
integration pack for OpenCode, OpenClaw, Hermes, pi, and NemoClaw. Follow with an
opt-in pi command for selecting an already configured local model. Keep
automatic per-turn switching behind separate correctness and privacy evidence.

An MCP connection exposes tools. It does not make a harness use quotabot's
recommendation as its next model. A displayed quota balance also does not prove
that the harness can use that same account, model, endpoint, or entitlement.
Keep these product states separate:

1. Harness detected.
2. Advisory connection configured and checked.
3. Matching target configured in the harness.
4. Matching target currently available in quotabot.
5. Explicit selection supported and tested for this harness version.

The [existing MCP examples](../../integrations/mcp_clients/README.md) already
provide Python and TypeScript clients. The
[LiteLLM integration](../../integrations/litellm/README.md) already provides an
optional external routing hook with authenticated reservations, releases, and
spend checks. Build on those contracts. Do not advertise a general ability to
turn coding subscriptions into interchangeable API deployments.

## Version evidence and compatibility matrix

Release metadata observed during the review:

| Project | Observed release or tag | Scope of evidence |
|---|---|---|
| OpenClaw | [v2026.9.1](https://github.com/openclaw/openclaw/releases/tag/v2026.9.1), published September 3 | Current official MCP, platform, provider, and plugin documentation |
| NemoClaw | [v0.0.119 tag](https://github.com/NVIDIA/NemoClaw/tree/v0.0.119) | Current official OpenClaw integration documentation; GitHub Latest release endpoint returned 404, so this is a tag observation |
| pi | [v0.85.0](https://github.com/badlogic/pi-mono/releases/tag/v0.85.0), published September 4 | Tagged extension and Windows documentation; current README |
| Hermes | [v2026.8.31](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.8.31) | Current official MCP, provider, plugin, and platform documentation |
| OpenCode | [v1.18.29](https://github.com/anomalyco/opencode/releases/tag/v1.18.29), published September 4 | Stable documentation and tagged plugin types; v2 documentation evaluated separately |

Documentation can move ahead of a release. Pin the exact package or binary
version in each integration test and retain the corresponding source reference.
None of the harness-specific cells below is a completed quotabot compatibility
certification.

| Harness | Practical advisory path | Possible selection path | Boundary that determines support |
|---|---|---|---|
| OpenCode 1 | Native stdio or authenticated loopback HTTP MCP; CLI also usable | User selects an already configured model; optional external LiteLLM deployment | Use the v1 schema. A provider listing is not proof of funded or included quota. |
| OpenCode 2 beta | Native MCP with a different configuration shape | Beta plugin API exposes session model switching | Separate preview track; do not ship v2 snippets as v1 configuration. |
| OpenClaw | Managed stdio or explicitly selected Streamable HTTP MCP; host CLI | Explicit plugin model override is documented | Match active Gateway runtime and allowed model/account; an installed plugin need not be active. |
| pi | CLI recipe or explicit extension command | Documented session model setter | No built-in MCP. Respect the session's model scope and existing authentication. |
| Hermes | Native stdio or Streamable HTTP MCP; CLI recipe | Existing user model picker; further automatic selection needs investigation | Main-model switching is different from a plugin's ability to make its own model call. |
| NemoClaw | Run quotabot on the host and present an advisory recommendation | User operates the managed route through NemoClaw | Current managed MCP cannot directly reach quotabot's loopback-only server. Host advice does not certify sandbox reachability. |

### OpenCode

OpenCode 1 config places server entries directly under `mcp`; local entries use
an executable argument array. HTTP entries support an authorization header with
environment substitution. For quotabot bearer authentication, set `oauth` to
`false`. This supplies tools, not a model-selection policy.
[Stable MCP documentation](https://opencode.ai/docs/mcp-servers/).

The v1.18.29 plugin type for `chat.params` exposes generation parameters and
options as its output. It is not a documented provider/model replacement result.
Do not implement a model router by assuming that mutating this hook's input
changes dispatch. Prove any alternative hook against tagged source and a fake
provider before describing it as supported.
[Tagged plugin types](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/plugin/src/index.ts).

OpenCode 2 is explicitly beta and runs as `opencode2` alongside `opencode`.
Its APIs and configuration may change; several distribution channels are not
supported during beta. Keep it in a separate compatibility lane.
[Beta introduction](https://opencode.ai/v2/docs).

V2 uses `mcp.servers`, `disabled` instead of `enabled`, and Streamable HTTP for
remote entries. Its plugin API documents `ctx.session.switchModel` and catalog
transforms, which merit an experimental explicit-selection example after the
stable pack. A catalog transform alone does not prove the model chosen by an
existing session.
[V2 MCP](https://opencode.ai/v2/docs/mcp-servers),
[V2 plugins](https://opencode.ai/v2/docs/build/plugins).

Local compatibility also requires exact model IDs and capabilities. Stable
OpenCode documents OpenAI-compatible Ollama configuration. V2 discovers Ollama
and vLLM, but deliberately does not infer vLLM tool support from discovery when
server parser flags are unknown. quotabot should preserve that uncertainty.
[Stable providers](https://opencode.ai/docs/providers),
[V2 local models](https://opencode.ai/v2/docs/models).

### OpenClaw

Current OpenClaw has an outbound MCP registry under `mcp.servers`. Its CLI
separates static status/doctor checks from explicit connection probes.
`openclaw mcp serve` instead exposes OpenClaw itself as an MCP server; it is not
the command for attaching quotabot. Use the outbound registry.
[MCP command reference](https://docs.openclaw.ai/cli/mcp).

HTTP MCP configuration defaults to SSE unless `transport` is
`streamable-http`. Header values support environment substitution. This is an
easy configuration error because quotabot's HTTP server is Streamable HTTP.
Prefer a source-aware stdio snippet for the first supported path.
[MCP configuration and transport](https://docs.openclaw.ai/plugins/bundles).

`before_model_resolve` supports provider/model overrides before session messages
load, but its event still includes prompt and attachment metadata. A future
adapter must ignore that event payload entirely and receive only a narrow
metadata projection. Do not serialize the event, collect transcripts, or use
raw-stream logging to verify the integration.
[Plugin hooks](https://docs.openclaw.ai/plugins/hooks).

Cold plugin inspection does not prove the running Gateway loaded the plugin.
Native runtime registration and a fake-provider dispatch assertion are required
before claiming automatic switching. Also preserve OpenClaw's distinction
between provider/model identifiers, runtime selection, and independently
configured authentication.
[Plugin lifecycle](https://docs.openclaw.ai/tools/plugin),
[Provider and runtime rules](https://docs.openclaw.ai/concepts/model-providers).

### pi

pi's README still explicitly excludes built-in MCP and directs users toward
CLI tools or extensions. Ship a CLI recipe first instead of inventing a
`mcpServers` configuration for pi.
[Current pi README](https://github.com/badlogic/pi-mono/blob/9841914c71a74d81abe07f751aefd271fd924e63/packages/coding-agent/README.md).

The v0.85.0 extension contract supplies custom commands, model-registry access,
session model scopes, and `pi.setModel`. The setter changes the current session,
is recorded by pi in session history, and does not replace new-session defaults.
It returns false when provider authentication is not configured. The tagged
documentation now imports `@earendil-works/pi-coding-agent`; older examples using
a different package scope should not be copied without version checks.
[Tagged extension contract](https://github.com/badlogic/pi-mono/blob/v0.85.0/packages/coding-agent/docs/extensions.md).

This is the clearest first selection experiment: an operator invokes a dedicated
command; the extension asks quotabot about local candidates; a deterministic
mapping intersects those candidates with pi's permitted model set; pi performs
the requested selection. Keep the extension outside quotabot's collector and
ship it as an explicitly user-applied artifact. It must not directly read or
write pi's credentials, settings, session files, or conversation objects.

### Hermes

Hermes supports stdio and Streamable HTTP MCP under `mcp_servers`; SSE is an
explicit alternative. Its compact configuration reference also documents
protocol-era negotiation and tool filters. Use ordinary legacy negotiation
compatible with quotabot's tested MCP server, with no new protocol assumption.
[MCP configuration reference](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference).

MCP sampling is enabled by default in current Hermes when supported by the SDK.
The quotabot example should explicitly disable sampling and expose only the
advisory tools needed. This does not change quotabot's own zero-inference
behavior; it makes the harness-side intent clear.
[Hermes MCP guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp).

The user-facing `hermes model` setup flow configures providers, while `/model`
selects among configured choices. These choices can represent different
subscription, aggregator, API-key, or local execution paths. A matching provider
name in quotabot is insufficient to prove an account/entitlement match.
[Inference providers](https://hermes-agent.nousresearch.com/docs/integrations/providers/).

Hermes plugins have observer hooks with conversation-bearing payloads. Its
separate plugin LLM API permits host-owned inference, including permission-gated
provider overrides. That is not a metadata-only API for changing the main
conversation model. Keep the first integration advisory; do not wrap model calls
or use `ctx.llm` for verification.
[Plugin contracts](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins),
[Plugin LLM access](https://hermes-agent.nousresearch.com/docs/developer-guide/plugin-llm-access).

### NemoClaw and OpenShell

NemoClaw currently supports managed authenticated Streamable HTTP MCP through
OpenShell's egress policy and credential substitution. It does not provide a
host stdio bridge. Its current documentation pins OpenShell 0.0.106 for this
surface.
[Managed MCP architecture](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/manage-sandboxes/mcp-servers/about-managed-mcp-servers).

Managed MCP endpoints require HTTPS and an explicitly routable address. They
reject loopback and host bridge aliases, including `host.openshell.internal` and
`host.docker.internal`. Consequently, quotabot's authenticated loopback MCP is
not a drop-in managed NemoClaw endpoint. Do not solve this by widening quotabot's
listener, copying provider credentials into a sandbox, or relaxing OpenShell
policy. Mark sandbox connection unsupported and retain host-side advisory use.
[MCP endpoint requirements](https://docs.nvidia.com/nemoclaw/latest/user-guide/openclaw/manage-sandboxes/mcp-servers/add-an-mcp-server).

Avoid the generic `nemoclaw <name> status` command in zero-token diagnostics:
current documentation says it sends an inference health request when the route
is reachable. Route changes may also validate by generating tokens, and the
documented host-bridge exception does not make `--no-verify` a universal
zero-inference guarantee. `inference get --json` is the documented route read;
its result proves a configured route, not model health or available quota.
Review the installed version before invoking any harness diagnostic.
[Command reference](https://docs.nvidia.com/nemoclaw/latest/user-guide/openclaw/reference/commands),
[Route inspection](https://docs.nvidia.com/nemoclaw/latest/inference/switch-inference-providers.html).

NemoClaw's local inference passes through `inference.local` and OpenShell to the
host endpoint. A host-local Ollama result must not be presented as evidence that
the sandbox can reach it or that its route currently selects that model.
[Local inference architecture](https://docs.nvidia.com/nemoclaw/latest/inference/use-local-inference.html).

## Platform and local-runtime implications

| Harness | Current upstream platform evidence | quotabot integration consequence |
|---|---|---|
| OpenClaw | Native Windows CLI/Gateway and Windows Hub are documented; WSL2 remains a supported Gateway runtime. [Windows](https://docs.openclaw.ai/platforms/windows) | Distinguish Windows-host and WSL process locations; a Windows binary path is not a Linux executable path. |
| pi | Windows defaults to Git Bash and has an optional PowerShell tool. [v0.85.0 Windows](https://github.com/badlogic/pi-mono/blob/v0.85.0/packages/coding-agent/docs/windows.md) | Use executable plus argument arrays, test spaces and Unicode paths, and avoid shell-specific snippets as the only entry point. |
| Hermes | Tier 1 includes Apple Silicon macOS, native Windows x64/ARM64, and Linux/WSL2 x64/ARM64. Intel macOS is explicitly unsupported. [Platform matrix](https://hermes-agent.nousresearch.com/docs/getting-started/platform-support) | Do not advertise an undifferentiated all-macOS compatibility badge. |
| NemoClaw | Linux is the primary tested path; Apple Silicon macOS and WSL2 have limitations. Native Windows is unsupported. [Prerequisites](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/get-started/prerequisites) | Report host advisory compatibility separately from sandbox/provider qualification. |
| OpenCode | Stable Windows guidance recommends WSL; v2 beta has separate installation constraints. [Windows](https://opencode.ai/docs/windows-wsl), [v2 introduction](https://opencode.ai/v2/docs) | Maintain explicit stable versus beta and native versus WSL fixtures. |

Hermes now has a managed llama.cpp runtime, and pi also exposes a managed
llama.cpp workflow. Those models are not covered merely because quotabot
supports Ollama, LM Studio, and Lemonade. A future bounded llama.cpp metadata
adapter could add useful coverage across harnesses. Read the runtime's own
metadata endpoint, preserve unknown tool/context capability, and keep model
download, startup, loading, and benchmarking outside collection.
[Hermes local runtime](https://hermes-agent.nousresearch.com/docs/user-guide/local-models),
[pi local workflow](https://github.com/badlogic/pi-mono/blob/v0.85.0/packages/coding-agent/docs/llama-cpp.md).

## First implementation slice

Ship an advisory integration pack with a machine-readable compatibility manifest
and reproducible examples:

1. Provide OpenCode 1, OpenClaw, and Hermes stdio configuration fragments with
   explicit version labels. Add loopback HTTP variants with bearer environment
   references, correct transport fields, and no literal secrets.
2. Provide a pi CLI recipe and a NemoClaw host-side recipe. State explicitly
   that the former has no built-in MCP and the latter has no supported managed
   connection to quotabot's loopback server.
3. Generate snippets only to stdout or a new user-selected artifact. Do not
   merge into host configuration, launch a harness, install extensions, or
   change its model automatically.
4. Resolve a real executable/source path. The current install and setup scripts
   do not ship a `quotabot-mcp` executable. Existing MCP examples start Dart in
   `collector/`; a printed configuration must not assume an absent binary.
   Evaluate a packaged MCP entry point as its own tested usability improvement.
5. Every example links to its exact tested harness version, protocol, OS lane,
   authentication source, and current support level. Untested and unsupported
   combinations receive those literal labels.

Acceptance evidence should include parsing each emitted JSON/YAML artifact,
native temporary-directory stdio startup on Windows/macOS/Linux, bounded MCP
initialize/tools-list/suggestion calls against synthetic metadata, and HTTP
unauthorized, oversized-body, and transport tests. Do not start a real agent
conversation to prove connectivity. Require the existing full lint and CI gates
and at least 80 percent coverage for introduced executable logic.

## Next selection experiment and near-future sequence

The first optional selector should be a pi local-only command. Accept only fixed
metadata arguments such as routing policy and capability profile. Bound the
quotabot process runtime and output size; validate the schema and candidate
shape; intersect exact provider/model IDs with an explicit target map and the
session's permitted models. Reject stale, drifted, unavailable, cloud-offloaded,
unmapped, or paid targets. A missing service or rejected target leaves selection
unchanged and displays the reason.

The operator's command authorizes pi's own model setter. quotabot still does not
write host state files. The extension must ignore conversation data, avoid
authentication resolution APIs that expose secrets, and never call a model.
Use fake registry and setter contracts to prove selection, refusal, cancellation,
and no hidden inference. Add a real pinned-runtime test with synthetic providers
before labeling it supported.

After that slice:

| Order | Work | Evidence needed before release |
|---|---|---|
| 1 | Improve installation and advisory visibility across the five harnesses | Versioned config fixtures, real metadata transport tests, clear connection state, three-OS path checks |
| 2 | pi explicit local model selection | Scoped model intersection, exact mapping, session-only selection, malformed/stale/offloaded rejection, no prompt or credential access |
| 3 | OpenClaw opt-in selection adapter | Exact active runtime, metadata-only projection before the hook, authenticated target matching, fake-provider dispatch and fallback tests |
| 4 | OpenCode 2 experimental selector | Pinned beta API, explicit session switching, independent v1 fixtures, no claim that a beta is stable |
| 5 | Hermes further selection support | A demonstrated main-model selection contract that does not require content-bearing middleware or inference wrapping |
| 6 | NemoClaw deeper support | A separately reviewed sandbox metadata boundary compatible with both projects' network and credential contracts |

Any future cloud selector needs exact account binding and explicit entitlement
evidence. Paid API, prepaid credit, included subscription quota, and local
execution remain separate spend classes. Do not infer account identity from
similar labels or use a quota lease as evidence of execution authorization.
Reservations and releases become necessary when an adapter actually coordinates
parallel remote dispatch, not when it merely displays an advisory answer.

A useful local dashboard should show harness connection, selected mapped model,
loaded/cold evidence, running context, separately labeled host pressure, and the
reason a recommendation cannot be applied. It should not claim throughput,
model-specific utilization, effective sandbox reachability, or billing safety
that metadata does not establish. This sequence improves everyday usefulness
without depending on official stores, publisher identity procurement, model
inference, or a paid research service.
