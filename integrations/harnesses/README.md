# Advisory integrations for agent harnesses

Connect a harness to quotabot's quota tools, or consult the CLI before choosing
a model. These examples do not automatically select a model or route a request.
They do not read or modify a harness's configuration, credentials, or sessions.

Originally reviewed against quotabot 0.10.3; tool visibility was rechecked on
2026-09-05 against the pinned upstream commits below. Installed-harness loading
has not been validated;
parseable configuration and a working quotabot transport do not prove that a
particular harness has loaded it.

| Harness | Reviewed version | This pack provides |
|---|---|---|
| OpenCode 1 | 1.18.29 | Stdio and authenticated loopback HTTP configuration |
| OpenClaw | 2026.9.1 | Stdio and authenticated loopback HTTP configuration |
| Hermes | 2026.8.31 | Stdio and authenticated loopback HTTP configuration |
| pi | 0.85.0 | [CLI advisory recipe](pi.md); no built-in MCP client |
| NemoClaw | 0.0.119 tag | [Host CLI recipe](nemoclaw.md); managed loopback MCP unsupported |
| OpenCode 2 | Beta documentation | Future and untested; no configuration emitted |

The machine-readable [compatibility record](compatibility.json) contains exact
source links and support labels. The wider
[research report](../../docs/research/2026-09-harnesses.md) explains the boundaries.

## Use the native CLI

quotabot 0.11.0 or a source build containing `quotabot mcp` can run the MCP
server from the normal native CLI bundle. Print a configuration using its
existing executable path:

```text
python integrations/harnesses/render_config.py opencode-1 --quotabot /absolute/path/to/quotabot
python integrations/harnesses/render_config.py openclaw --quotabot /absolute/path/to/quotabot
python integrations/harnesses/render_config.py hermes --quotabot /absolute/path/to/quotabot
```

Windows PowerShell example, using your installed native CLI path:

```powershell
python integrations/harnesses/render_config.py openclaw --quotabot 'C:\Tools\quotabot\bin\quotabot.exe'
```

The renderer adds `mcp` as a separate argument. It checks file existence and
path safety; it never executes the file or probes its version. You must supply
0.11.0 or a supporting source build, with the complete native bundle intact.
`--quotabot`, `--dart`, and `--executable` are mutually exclusive and are only
valid for stdio. Omitting all three keeps the source launch below as the default.

## Print a stdio configuration

Python 3.10 or later is sufficient to print configuration. No Python packages
are required. The default source path is this checkout's `collector/` directory;
the renderer checks that the actual MCP entry point and package file exist.
It resolves Dart on PATH or accepts its existing executable path with `--dart`.

Prepare collector dependencies using the repository's pinned setup, then run
from the repository root:

```text
python integrations/harnesses/render_config.py opencode-1
python integrations/harnesses/render_config.py openclaw
python integrations/harnesses/render_config.py hermes
```

For a Dart SDK outside PATH:

```text
python integrations/harnesses/render_config.py openclaw --dart /absolute/path/to/dart
```

Windows PowerShell example, substituting the existing SDK path:

```powershell
python integrations/harnesses/render_config.py opencode-1 --dart 'C:\SDKs\dart-sdk\bin\dart.exe'
```

Use the SDK's native `dart.exe` on Windows instead of a `.bat` or `.cmd` wrapper.
The configuration keeps command arguments separate and uses an absolute working
directory, so it does not depend on the harness's project directory. If Dart's
native-asset build has a platform path restriction, use the repository's
[source setup guidance](../../docs/BUILDING.md).
Source launch sets `--verbosity=error` to suppress routine Dart build progress
on stderr. The MCP protocol stays on stdout.

Output is a JSON configuration fragment on stdout. Review it and manually merge
its top-level mappings into the harness configuration using that harness's own
controls. For Hermes, translate the `mcp_servers` mapping into the existing
`config.yaml`, or use its JSON mapping representation where accepted; do not
replace the rest of the file. The renderer never opens a host config file.

If you already built a native MCP executable, pass its real path:

```text
python integrations/harnesses/render_config.py hermes --executable /absolute/path/to/mcp_server
```

The renderer checks that the file exists; it does not execute it or certify what
it contains. Keep any required native libraries beside it in its complete build
bundle. The normal quotabot CLI release does not ship `quotabot-mcp`, and the
standalone `--executable` mode passes no subcommand. Use `--quotabot` for the
normal CLI from 0.11.0 onward so `mcp` is supplied. Source launch remains the
default in these examples.

On Windows, do not start several `dart run` processes from the same collector
checkout while another process holds its native SQLite library. Dart's native
asset preparation can fail when replacing that DLL. For concurrent daily use,
prefer an existing compiled MCP bundle, or use independent source checkouts.
Stop collector tests and other source processes before running the smoke below.

## Print an HTTP configuration

Use this only when the harness and quotabot share the same host loopback
network. A remote Gateway, container, or WSL process may have a different
loopback namespace. Start the existing authenticated MCP server as described
in [MCP clients](../mcp_clients/README.md#start-quotabot), using port 8722 and path
`/mcp`. That guide keeps its bearer token in `QUOTABOT_MCP_TOKEN`.

Then print a fragment:

```text
python integrations/harnesses/render_config.py opencode-1 --transport http
python integrations/harnesses/render_config.py openclaw --transport http
python integrations/harnesses/render_config.py hermes --transport http
```

These fragments use exactly `http://127.0.0.1:8722/mcp`. They contain an
environment reference for the bearer header, never the token value. Ensure the
harness process inherits the same secret from your protected environment.
Rendering does not read that variable, contact the server, or launch a harness.
Keep proxy handling appropriate for loopback in the harness's environment.

quotabot currently speaks MCP `2025-11-25` with the legacy `initialize`
handshake over stdio or Streamable HTTP. The `2026-07-28` MCP specification is
final, but this pack does not implement its stateless lifecycle. A compatible
harness must retain legacy negotiation. Hermes is explicitly set to `legacy`.
[quotabot server](../../collector/bin/mcp_server.dart),
[final specification announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/).

## Harness configuration details

OpenCode 1 uses `mcp.quotabot`, a local command array, and its documented
environment substitution for HTTP headers. Automatic OAuth is disabled for
quotabot's bearer-only endpoint. The two current lease tools are disabled by
name in the tool configuration. Other MCP metadata tools remain visible.
[OpenCode MCP](https://opencode.ai/docs/mcp-servers/).

OpenClaw uses `mcp.servers.quotabot.toolFilter.include` for its advisory
allowlist. `tools.include` is not an alias in the reviewed runtime and would
leave the tools unfiltered. Its generated resource/prompt helpers pass through
the same allowlist, so they remain hidden.
Its HTTP fragment explicitly selects `streamable-http`; omitting this would
select SSE in current OpenClaw. This is an outbound MCP client configuration.
`openclaw mcp serve` instead exposes OpenClaw itself and is not needed here.
[MCP reference](https://docs.openclaw.ai/cli/mcp),
[transport details](https://docs.openclaw.ai/plugins/bundles),
[pinned filter implementation](https://github.com/openclaw/openclaw/blob/ad6fe23aecb9b833d68139b0ddc9f239b894d2f1/src/agents/agent-bundle-mcp-runtime.ts).

Hermes uses `mcp_servers.quotabot.tools.include` and separately sets
`tools.resources: false` and `tools.prompts: false`. These utility families
default to enabled independently of the native tool allowlist. MCP sampling
is disabled. Its default URL transport is Streamable HTTP. The pinned implementation
accepts a stdio working directory and separate executable/argument fields.
[configuration reference](https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference),
[MCP sampling](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp),
[pinned transport and utility policy](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tools/mcp_tool.py).

Both recipes expose exactly six advisory tools: `decide_now`, `list_quotas`,
`suggest_provider`, `check_provider_availability`, `list_models`, and
`suggest_model`. Lease operations and resource/prompt helpers remain hidden.
If you applied an earlier fragment, render a new one and replace only the
quotabot server entry using the client's configuration controls. For OpenClaw,
remove the old `tools` key when adding `toolFilter`; for Hermes, retain the
include list and add both explicit utility toggles.

Client tool filters control visibility in that harness. They are not a server
authorization boundary. Metadata calls can still refresh quotabot's own cache,
grants, and bounded local state as described in [AGENTS.md](../../AGENTS.md).

OpenCode 2 is explicitly beta, runs as `opencode2`, and uses different config
fields including `mcp.servers` and `disabled`. Keep the v1 fragments with v1.
This pack deliberately rejects `opencode-2` as a renderer target until a
separate versioned example is validated.
[Beta introduction](https://opencode.ai/v2/docs),
[beta MCP shape](https://opencode.ai/v2/docs/mcp-servers).

## Read a recommendation

Use `decide_now` for cached advice with explicit age and staleness. Use
`suggest_provider` for a live metadata recommendation, or `suggest_model` with
fixed capability metadata such as `task: standard` and `budget: quota`.
Use `list_models` with `budget: local` to inspect on-device candidates.

Do not send prompt text, code, responses, credentials, or raw harness events as
tool arguments. A quota read makes no inference request; ordinary harness
reasoning around MCP tools may still use that harness's model budget.

Before applying a suggestion, match the target's exact provider, model, account,
availability, and spend class to a route you already configured in the harness.
Use existing authorized accounts and provider-supported access under the
applicable terms. Respect reported limits; quotabot does not override or
circumvent them.
Paid API keys do not inherit a provider's separate subscription quota. A model
served through a local daemon may still execute in the cloud. Nothing in these
configurations adds an inference provider or enables paid fallback.

If quotabot is missing, unavailable, stale, or has no matching safe target, keep
the harness's original behavior. An advisory connection is not a dispatch
integration or proof of model execution.

## Validation

Run the dependency-free configuration and source-entrypoint tests:

```text
python -m unittest discover -s integrations/harnesses -p "test_*.py"
```

The configuration tests check machine-readable output, real source/file
assumptions, paths, the three different config shapes, fixed loopback endpoints,
secret references, disabled sampling, and absence of model/provider changes.
An independent [source-derived catalog fixture](fixtures/README.md) pins the
OpenClaw and Hermes filter rules to exact commits. Its tests compare rendered
recipes with the six-tool catalog and reproduce the ignored-key and implicit
utility-default failures. They do not run either upstream harness.
The optional entrypoint smoke runs only when `QUOTABOT_HARNESS_SMOKE=1` or an
explicit `QUOTABOT_HARNESS_TEST_DART` executable path is supplied. It uses that
path or resolves Dart from PATH and performs only legacy MCP initialization and
tool-list exchange. It isolates the child home directories and removes provider
credentials from the child's environment. It never invokes a quota tool, model,
harness diagnostic, or onboarding command.
The returned native catalog is also checked against the same source-derived
visibility contract. This proves that the requested advice tools exist in the
actual server, while successful client loading remains a separate check.

Run it sequentially after other collector processes finish. Bash:

```bash
QUOTABOT_HARNESS_SMOKE=1 python -m unittest discover -s integrations/harnesses -p 'test_mcp_entrypoint.py'
```

PowerShell, with Dart already on PATH:

```powershell
$env:QUOTABOT_HARNESS_SMOKE = '1'
python -m unittest discover -s integrations/harnesses -p 'test_mcp_entrypoint.py'
Remove-Item Env:QUOTABOT_HARNESS_SMOKE
```

An executed quotabot entrypoint smoke proves the server launch contract on that
host. It does not prove the harness parsed the fragment, loaded its filters,
inherited its environment, or changed its selected model. Native harness smoke
remains unverified in the compatibility record.

An isolated Windows attempt on 2026-09-05 used the exact OpenClaw `2026.9.1`
distribution, Node `24.15.0`, the corrected renderer, and the native quotabot
CLI. Its `mcp probe quotabot --json` startup hit the fixture's synchronous-child
process restriction before MCP initialization. No catalog was obtained, so
this is an incomplete validation attempt. Input configuration and the quotabot
bundle were unchanged, and the isolated quotabot profile stayed empty. The
source-derived filter checks above pass independently; they do not turn this
attempt into a supported native-loader claim.

On 2026-09-05, the installed Windows OpenCode package and its native
`--version` output both identified version `1.15.13`, older than the reviewed
`1.18.29` configuration baseline. The version check ran from a temporary
directory with isolated home, application-data, XDG, managed-config, and temp
paths. It exited successfully with no stderr and created no files in that
temporary profile. No MCP loader command was run.

The installed binary and its tagged source show that `mcp list` initializes
configured MCP servers and discovers their tools, but also enters instance
bootstrap. Configuration loading schedules installation of `@opencode-ai/plugin`
for configuration directories, including the global directory. The `--pure`
flag does not guard that installation path. This diagnostic was therefore
excluded from the no-install, no-download validation. The result verifies the
installed version only; it does not establish OpenCode `1.15.13` compatibility
or native-client loading for the pack's `1.18.29` baseline.
[MCP list command](https://github.com/anomalyco/opencode/blob/v1.15.13/packages/opencode/src/cli/cmd/mcp.ts),
[instance bootstrap](https://github.com/anomalyco/opencode/blob/v1.15.13/packages/opencode/src/cli/effect-cmd.ts),
[configuration loading](https://github.com/anomalyco/opencode/blob/v1.15.13/packages/opencode/src/config/config.ts),
[dependency installation](https://github.com/anomalyco/opencode/blob/v1.15.13/packages/core/src/npm.ts).
