# MCP and Agent Plugins compatibility review

Reviewed 2026-09-13 against quotabot 0.11.5 at
`4c502b777389003f1a25f5a0556e234db3b369b6`, with a fresh native Windows CLI build.
[ROADMAP.md](../../ROADMAP.md#next) owns execution order. This report records
verified behavior, primary sources, and requirements for the compatibility work.

## Current versions and their meaning

| Surface | Current evidence | Quotabot consequence |
|---|---|---|
| Final MCP core | The [latest specification URL](https://modelcontextprotocol.io/specification/latest) resolves to `2026-07-28` | This is the modern protocol target. |
| MCP roadmap | The [August 22 roadmap](https://blog.modelcontextprotocol.io/posts/mcp-roadmap/) describes work after the July release | It is not another published wire revision. Do not implement proposed behavior as a shipped requirement. |
| Dart SDK | [mcp_dart 2.4.2 changelog](https://pub.dev/packages/mcp_dart/changelog); quotabot locks 2.2.2 | Stable 2.3 added modern and legacy profiles. Version 2.4.2 bounds incoming stdio and IO messages. A supported upgrade path now exists. |
| Agent Plugins | [Published specification](https://agent-plugins.org/specification) remains 1.0.0 | Package-format version and MCP wire version are independent. The package's own release version is a third value. |

The pub registry dates SDK 2.4.2 to September 3. The upstream
[transition guide](https://github.com/leehack/mcp_dart/blob/v2.4.2/doc/mcp-2026-07-28.md)
allows explicit `McpProtocol.legacy` as an intermediate migration step. Use that
boundary if needed to separate bounded-stdio security intake from the larger
modern transport change; stricter validators still need regression review.

The SDK's newer default prefers modern discovery and can fall back to legacy
initialization. An upgrade is therefore not behavior-neutral. Its release notes
also describe changes to validation errors, structured output, cancellation, and
subscriptions. Review and regenerate both Dart package lockfiles with the native
package manager on a first-party branch; do not reuse a dependency-bot branch.

The security update deserves immediate intake. Quotabot constructs
`StdioServerTransport()` directly. The locked SDK appends incoming chunks to a
read buffer until a newline arrives, with no per-message byte ceiling in that
path. Its HTTP wrapper's 256 KiB admission limit does not protect stdio. No
memory-exhaustion experiment was performed. This is static dependency-impact
evidence, not a claim of a remotely reachable unauthenticated network exploit.

## Verified compatibility matrix

| Check | Result on the reviewed Windows tree | What it proves |
|---|---|---|
| MCP 2024-11-05 native plugin launch | Passed | Exact requested initialization revision, required tool discovery, protocol-only stdout, and clean EOF exit |
| MCP 2025-03-26 native plugin launch | Passed | Same bounded launch checks |
| MCP 2025-06-18 native plugin launch | Passed | Same bounded launch checks |
| MCP 2025-11-25 native plugin launch | Passed | Same bounded launch checks |
| Modern `server/discover` probe | Rejected with JSON-RPC `-32600`, requiring initialization first | Current native server does not implement the modern discovery path |
| Core MCP, HTTP, shutdown, and subscription-timer tests | 97 passed | Existing fixture-based tool, transport, and lifecycle behavior |
| Agent Plugins tests with fresh 0.11.5 bundle | 16 passed, including four revision subtests | Manifest, schema, preparation, and native launch checks |
| Current canonical plugin and MCP schemas | Both byte-identical to vendored copies | Existing offline schemas remain current |
| Actual plugin loading inside a named client | Not performed | No new installed-client support claim is justified |
| Modern HTTP, subscriptions, and cross-language clients | Not implemented or verified here | Remains required compatibility work |

The native tests use empty isolated profile and plugin-data directories. They
do not read real host credentials, collect live quota, invoke models, install a
plugin into a client, or modify client configuration. Existing MCP unit tests
use synthetic quota and injected sources. A passing launch cannot establish
access to a user's real account.

## Required modern protocol integration

The [July change list](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
requires more than accepting a new version string. Add `server/discover`,
per-request version and capability metadata, required result discriminators,
deterministic catalog ordering, and explicit cache hints. Replace the modern
path's session-based change notifications with `subscriptions/listen` while
retaining the older subscription behavior for legacy peers.
Discovery is optional for clients: an ordinary modern request must also work
before `server/discover`. Every request declares its version and capabilities;
do not replace mandatory initialization with mandatory discovery.

`collector/lib/mcp_http.dart` currently admits a request without a session only
when it is `initialize`, and constructs a server during session initialization.
That boundary must accommodate stateless requests explicitly. Preserve bearer,
host and origin checks, body deadlines, size and concurrency bounds, and
shutdown ownership before delegating protocol handling to the SDK.

The [transport contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports)
defines different cancellation mechanics for stdio and HTTP. The modern HTTP
path must validate mirrored metadata and isolate cancellation to its request.
Validate `MCP-Protocol-Version` against `params._meta`'s protocol version,
`Mcp-Method` against root `method`, and required `Mcp-Name` against `params.name`
or `params.uri`. Header failures use HTTP 400 / `-32020`; unsupported
revisions use `-32022`. Modern HTTP has no protocol session or GET stream.

Quota resources need private cache scope, initially zero TTL, consistent with
their existing timestamps. The protocol's cacheable operations include
discovery, catalogs, and `resources/read`, not `tools/call`; do not add invented
tool cache fields. See the [caching contract](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching).

The current subscription hub uses a URI set and a shared callback. Modern
listeners need separate IDs, accepted URI subsets, delivery, and cancellation.
Cancelling one overlapping subscription must leave the other alive; closing
the last listener stops polling. Reuse the existing alert loop with explicit
ownership, following the [subscription contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions).

The [versioning contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
allows dual-era clients to fall back to older servers through documented
transport-specific detection. Test fallback with actual supported client SDKs,
including incompatible-version errors. The raw legacy tests do not prove that
a particular modern client performs that fallback.

Modern TypeScript uses the split `@modelcontextprotocol/client` package, now
[2.0.0](https://registry.npmjs.org/@modelcontextprotocol/client); the legacy
`@modelcontextprotocol/sdk` package is a different generation. Python's current
stable SDK is [2.2.0](https://github.com/modelcontextprotocol/python-sdk/releases/tag/v2.2.0),
published September 7. Exercise explicit modern APIs and legacy fallback; a
dependency version alone does not identify the wire path exercised.

Optional Tasks, sampling, elicitation, MCP Apps, and enterprise authorization
are separate capability decisions. A quota advisor should advertise only what
it implements. Modern protocol support does not require inference capabilities
or a new authentication service.

## Agent Plugins acceptance boundary

Agent Plugins 1.0.0 defines the root manifest, fixed component paths, separate
`mcp.json`, contained paths, and client-supplied `PLUGIN_ROOT` and `PLUGIN_DATA`.
It does not guarantee ambient home or account variables. Keep explicit path
preparation, shell-free executable launch, offline schema validation, and the
stdio package. Do not add a nonstandard protocol override or store a bearer
secret in package JSON. See the [runtime guidance](https://agent-plugins.org/client-implementers/mcp-runtime).

The [compatible-client directory](https://agent-plugins.org/compatible-clients)
lists clients with different component and transport support. For each named
support claim, record an exact client version, OS, loader action, skill
discovery, MCP startup, negotiated protocol, harmless fixture tool result,
missing-executable behavior, and shutdown. Use disposable client configuration
and synthetic evidence. Record generic package conformance separately from
client-specific extensions and account visibility.

## Named harness currency

These are current research baselines, not replacements for the pack's tested
configuration versions or proof of an installed loader.

| Harness | Primary release/source | Consequence |
|---|---|---|
| OpenClaw | [2026.9.4](https://github.com/openclaw/openclaw/releases/tag/v2026.9.4), published September 11 | The [bundle loader](https://docs.openclaw.ai/plugins/bundles) documents Agent Plugins skills, stdio, and HTTP. Prove enabled runtime loading and a fixture tool, not only bundle inspection. |
| OpenCode 1 | [1.18.30](https://github.com/anomalyco/opencode/releases/tag/v1.18.30), September 9 | Keep its native `mcp.<name>` configuration; [native plugins](https://opencode.ai/docs/plugins/) are JS/TS or npm modules. No portable loader claim follows. |
| Hermes | [2026.9.11 / 0.21.2](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.9.11), September 11 | Its [portable subset](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins#portable-agent-plugins-v1-packages) supports skills and stdio/Streamable HTTP. Explicit enablement is required. Test both legacy and modern negotiation. |
| pi | [0.85.1](https://github.com/earendil-works/pi/releases/tag/v0.85.1), September 5 | Repository moved to `earendil-works/pi`. Its [versioned README](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/README.md) still excludes built-in MCP. Use CLI advice unless a separate extension is verified. |
| NemoClaw | [v0.0.123 source commit](https://github.com/NVIDIA/NemoClaw/commit/f75f722bb4a1ec9642c8df36c8924e24500d78f0), committed September 11 | No GitHub latest-release record was found. [Managed MCP](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/manage-sandboxes/mcp-servers/about-managed-mcp-servers) uses canonical HTTPS endpoints, without a host stdio bridge. Retain host CLI advice. |
| OpenCode 2 | [Current V2 configuration](https://opencode.ai/v2/docs/mcp-servers) | Uses `mcp.servers.<name>` and `disabled`. Establish an exact release before adding support; V1 configuration is not V2 evidence. |

Hermes's [current negotiation code](https://github.com/NousResearch/hermes-agent/blob/v2026.9.11/tools/mcp_tool_transport.py)
defaults to legacy-first auto negotiation. A passing default smoke against a
dual-era server can miss the modern path entirely. OpenClaw and OpenCode 1 still
pin the legacy TypeScript SDK generation. Keep protocol mode in every receipt.

## Completion gates

- Review the stable SDK changes and bound stdio messages. Prove prompt closure
  on oversized input, including a frame with no newline, without weakening
  existing HTTP admission.
- Exercise both protocol paths over stdio and loopback HTTP. Include discovery,
  catalogs, normalized tool results and errors, quota resources, subscriptions,
  private caching, cancellation, duplicate identifiers, and shutdown races.
- Retain the four legacy native launch checks and test dual-era fallback
  with supported TypeScript and Python clients. Do not infer interoperability
  from a Dart client talking to the same Dart SDK.
- Run the real prepared plugin through each client whose support is claimed,
  with versioned disposable fixtures and no model call.
- Keep CLI, MCP, HTTP, and desktop normalized quota and routing contracts
  consistent. Update AGENTS, schema, client, harness, and plugin documentation
  with the implemented revision matrix.
- Pass the complete project gates, collector coverage of at least 90 percent,
  desktop coverage of at least 80 percent, and three-OS CI on the exact change.

These gates are not all closed. The current work improves the legacy test
matrix and establishes a concrete modern-protocol gap; it does not ship a new
MCP implementation or claim complete current-client compatibility.
