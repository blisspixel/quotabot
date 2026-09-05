# Tool visibility contract fixture

Reviewed 2026-09-05. [tool_visibility.json](tool_visibility.json) records bounded
facts from exact upstream commits, independently of the renderer's keys and
`ADVISORY_TOOLS` constant. No upstream executable code is copied or run.

OpenClaw 2026.9.1 at `ad6fe23aecb9b833d68139b0ddc9f239b894d2f1` reads
`rawServer.toolFilter` in its session MCP runtime. Config normalization clones
the server record, and the embedded merge preserves it; there is no
`tools` to `toolFilter` conversion. Both native tools and generated
resource/prompt utilities pass through the same filter. An absent or empty
include list leaves all names eligible unless excluded.
[Runtime](https://github.com/openclaw/openclaw/blob/ad6fe23aecb9b833d68139b0ddc9f239b894d2f1/src/agents/agent-bundle-mcp-runtime.ts),
[normalizer](https://github.com/openclaw/openclaw/blob/ad6fe23aecb9b833d68139b0ddc9f239b894d2f1/src/config/mcp-config-normalize.ts),
[merge](https://github.com/openclaw/openclaw/blob/ad6fe23aecb9b833d68139b0ddc9f239b894d2f1/src/agents/bundle-mcp-config.ts),
[filter](https://github.com/openclaw/openclaw/blob/ad6fe23aecb9b833d68139b0ddc9f239b894d2f1/src/agents/mcp-tool-filter.ts),
[utility materializer](https://github.com/openclaw/openclaw/blob/ad6fe23aecb9b833d68139b0ddc9f239b894d2f1/src/agents/agent-bundle-mcp-materialize.ts).

Hermes 2026.8.31 at `29112bef099274229cadff79cdff7bf7b99c4b77` reads
`tools.include` when registering native tools. Its separate
`_select_utility_schemas` path defaults resource and prompt wrappers to enabled
when the server advertises the corresponding capability. Each family needs
its own false toggle to stay outside an exact six-tool surface. An explicit
empty native include list differs from OpenClaw: Hermes registers no native
tools from it. [Registration and utility policy](https://github.com/NousResearch/hermes-agent/blob/29112bef099274229cadff79cdff7bf7b99c4b77/tools/mcp_tool.py).

The test projection intentionally covers only the exact-name include lists
and boolean utility toggles emitted by these recipes. It is not an
implementation of client loading, glob matching, schema conversion, execution,
or authentication. Negative controls show the broader catalog that results
from the old OpenClaw key and Hermes's omitted toggles. Synthetic future tools
and prompt capabilities verify that the explicit catalog remains bounded;
they are not claims about quotabot's current capabilities.

The optional metadata-only source smoke uses the real quotabot initialization
and tool list as input to this contract. It still does not execute a native
OpenClaw or Hermes loader. Keep installed-client smoke labeled unperformed
until that separate check runs successfully.
