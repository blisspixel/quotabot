# quotabot Agent Plugin

This directory is a portable Agent Plugins 1.0.0 package. It supplies a quota
advisory skill and a stdio connection to the existing quotabot MCP server. It
does not select a model, configure inference providers, or install dependencies
when loaded.

Reviewed 2026-09-04 against the published
[Agent Plugins specification](https://agent-plugins.org/specification).
The package version is independent of the quotabot application version.

## Prepare the executable

The client must resolve a native `quotabot` executable from 0.11.0 or later that
supports `quotabot mcp`, or a source build containing that command. Earlier
releases do not satisfy this prerequisite.
The existing release installers do not provide a separate `quotabot-mcp`.

From a source checkout with the repository's required SDK and native build
prerequisites, install the CLI:

```powershell
pwsh tools/setup.ps1 -CliOnly
```

```bash
bash tools/setup.sh --cli-only
```

Then check the installed command without collecting quota or invoking a model:

```text
quotabot mcp --help
```

Setup can fall back to an older release when source compilation is unavailable.
That fallback does not satisfy this plugin until the installed executable
actually supports `mcp`. Keep the CLI's complete native bundle, including its
SQLite library, intact. Make the executable available to the client process's
own executable search path; a terminal and a desktop client can have different
paths. See [source building](https://github.com/blisspixel/quotabot/blob/main/docs/BUILDING.md).

The MCP configuration uses a bare executable name, separate arguments, and a
working directory in client-managed `PLUGIN_DATA`. It has no shell wrapper,
download command, external package path, or command placeholder. A source
command that reaches outside this plugin directory is not a portable package
launch configuration.
[MCP runtime rules](https://agent-plugins.org/client-implementers/mcp-runtime).

## Keep the right profile visible

Agent Plugins clients choose which environment variables their subprocesses
inherit. The format guarantees `PLUGIN_ROOT` and `PLUGIN_DATA`; it does not
guarantee the user's home path, account credentials, runtime URLs, proxy values,
or hardware-tool environment. The generic [mcp.json](mcp.json) preserves the
environment that the client provides. It does not silently replace HOME or
claim access to the user's subscriptions.

quotabot resolves provider files through `USERPROFILE` or `HOME`, with
`APPDATA`, `LOCALAPPDATA`, and XDG paths used by some adapters. Its own metadata
root prefers `LOCALAPPDATA`, then `XDG_CONFIG_HOME`, then the home configuration
directory. If the client omits those paths, the plugin data directory is the
working-directory fallback; host account evidence may be absent. Native runtime
metadata and optional hardware details are also limited by the client's host,
network namespace, and environment.
[Current path implementation](https://github.com/blisspixel/quotabot/blob/main/collector/lib/util.dart),
[environment contract](https://agent-plugins.org/specification#9-environment-variables-and-placeholder-expansion).

For a client that strips profile paths, `prepare_mcp.py` uses Python 3.10 or
later to print a personal configuration from the directory paths you explicitly
supply. It reads no environment variables, credential files, or host
configuration and writes no files. Paths must already exist. For example, in
PowerShell:

```powershell
python integrations/agent_plugin/prepare_mcp.py --home "$env:USERPROFILE" --app-data "$env:APPDATA" --local-app-data "$env:LOCALAPPDATA"
```

For a default Unix home layout:

```bash
python integrations/agent_plugin/prepare_mcp.py --home "$HOME"
```

If you use nondefault XDG directories, explicitly supply the existing paths
with `--xdg-config-home` and `--xdg-data-home`. Review the printed JSON and save
it as `mcp.json` in your personal copy of this package. Keep that personalized
copy private and preserve your changes when updating it. This step stores
nonsecret path values, not credentials. It neither copies credentials into the
package nor changes their files. Client policies still determine what the
subprocess may access; path configuration is not authentication.

Use the [native harness configurations](https://github.com/blisspixel/quotabot/tree/main/integrations/harnesses) when client-specific
credential handling or authenticated loopback HTTP is needed. Agent Plugins
1.0.0 does not expand arbitrary environment references in headers and provides
no portable credential-reference field, so this package ships no HTTP entry.

## Load the package directory

The plugin root is `integrations/agent_plugin`, not the repository root.
`plugin.json`, `mcp.json`, and `skills/quota-advice/SKILL.md` must remain together.
No marketplace publication is required for directory loading.
[Loading and discovery](https://agent-plugins.org/client-implementers/loading-and-discovery).

Current official documentation describes these directory-loading paths:

| Client | Documented path | Evidence level here |
|---|---|---|
| OpenClaw | From this repository root, `openclaw plugins install ./integrations/agent_plugin` | [Documented bundle loading](https://docs.openclaw.ai/plugins/bundles); installed-client smoke unperformed |
| VS Code | Add this package's absolute directory to `chat.pluginLocations` using the client's settings controls | [Documented local plugins](https://code.visualstudio.com/docs/agent-customization/agent-plugins#_use-local-plugins); installed-client smoke unperformed |
| Hermes | Use the portable package installation and explicit enablement flow in its plugin guide | [Documented portable subset](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins#portable-agent-plugins-v1-packages); installed-client smoke unperformed |

Those client documents are current references, not a verified minimum-version
matrix. The [compatible-client directory](https://agent-plugins.org/compatible-clients)
lists additional implementations with different component support. A client
may support skills without supporting this stdio transport. This package makes
no Agent Plugins loading claim for pi, OpenCode, or managed NemoClaw; their
separate [harness recipes](https://github.com/blisspixel/quotabot/tree/main/integrations/harnesses) still apply.

quotabot currently uses legacy MCP `2025-11-25` initialization. The client must
retain that negotiation path. The final MCP `2026-07-28` lifecycle is a separate
protocol change that this package does not implement. Agent Plugins 1.0.0 has
no portable protocol-version override, so no unsupported field is added to
`mcp.json`.

## Use the advice

Discover the `quota-advice` skill through the client's own skill controls. The
skill leads with provider headroom and named-account availability. Local-model
details are optional. Use existing authorized accounts and provider-supported
access under the applicable terms; reported limits are respected, never
overridden or circumvented. The skill explains stale evidence and keeps paid
API routes distinct from subscription entitlements. If the MCP
component cannot launch, the skill can use an already installed CLI or explain
the missing prerequisite while leaving the user's original work in place.

Loading this package does not make every quotabot tool read-only. The existing
server also exposes named quota lease operations, and the portable format has
no standard tool allowlist. The advisory skill does not invoke those operations
or establish background subscriptions. Apply any extra tool visibility policy
through the client's own controls. Quotabot's live reads can refresh its own
bounded cache and history and contact provider metadata endpoints; they never
invoke a model or read prompts, code, or responses. Harness reasoning around
tools can still use the harness's model budget.

## Validate without inference

Development tests use the repository's existing pinned `jsonschema` and
`PyYAML` dependencies from `integrations/litellm/requirements.txt`; the plugin
runtime does not require Python or those packages. Once those development
dependencies are installed:

```text
python -m unittest discover -s integrations/agent_plugin -p "test_*.py"
```

The tests validate the real manifest and MCP JSON against vendored canonical
schemas without fetching anything, validate skill frontmatter and package
containment, and exercise the explicit path renderer without host writes,
credentials, or subprocess model calls. Schema sources, hashes, and the
required upstream license are retained in [tests/schemas](tests/schemas/).
These checks prove package structure and preparation behavior. Actual client
loading and credential visibility remain separate validation requirements.

An additional smoke test runs only when `QUOTABOT_PLUGIN_TEST_EXECUTABLE`
explicitly names an existing native `quotabot` or `quotabot.exe` from 0.11.0
onward. Supply the executable from its complete platform bundle. For example:

```bash
QUOTABOT_PLUGIN_TEST_EXECUTABLE=/absolute/path/to/bin/quotabot python -m unittest discover -s integrations/agent_plugin -p 'test_mcp_bundle.py'
```

```powershell
$env:QUOTABOT_PLUGIN_TEST_EXECUTABLE = 'C:\Tools\quotabot\bin\quotabot.exe'
python -m unittest discover -s integrations/agent_plugin -p 'test_mcp_bundle.py'
Remove-Item Env:QUOTABOT_PLUGIN_TEST_EXECUTABLE
```

The smoke prepares the real package with empty profile and plugin-data
directories, resolves its bare command to the supplied executable, and performs
only legacy MCP initialization, tool discovery, and EOF shutdown. It checks
protocol-only stdout and leaves no profile metadata. The child inherits only
basic operating-system executable-search values plus the isolated paths, with
no provider credentials. It calls no quota tools, subscribes to no resources,
and invokes no model or client diagnostics. A passing result proves native
bundle execution and this prepared launch contract on that host; it does not
prove a particular client loaded the package or can access the user's accounts.
