# NemoClaw host advisory recipe

Reviewed against the NemoClaw 0.0.119 tag and current official documentation on
2026-09-04. Run quotabot on the host where its provider credentials and local
runtime metadata are available:

```text
quotabot suggest --json
quotabot models --budget=local --json
quotabot suggest --task=standard --budget=quota --json
```

This is host-side advice. It does not change a NemoClaw route, inspect a
conversation, certify sandbox connectivity, or send inference requests. The
operator can compare the recommendation with the route already configured in
NemoClaw and use NemoClaw's own controls if a change is desired.

Managed NemoClaw MCP accepts authenticated Streamable HTTP through OpenShell.
Its endpoints must use HTTPS and a routable address; loopback and host bridge
aliases are rejected. quotabot's loopback-only MCP server therefore has no
supported managed connection in this pack. Do not copy an OpenClaw host snippet
into a sandbox and assume its loopback reaches the host.
[Architecture](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/manage-sandboxes/mcp-servers/about-managed-mcp-servers),
[Endpoint requirements](https://docs.nvidia.com/nemoclaw/latest/user-guide/openclaw/manage-sandboxes/mcp-servers/add-an-mcp-server).

Do not use generic NemoClaw status or route-changing commands as zero-token
connection tests. Current `status` diagnostics can send inference requests, and
route changes can perform generation-based validation. The exact installed
version determines this behavior. The documentation distinguishes route
inspection from inference verification, but this pack executes neither.
[Command reference](https://docs.nvidia.com/nemoclaw/latest/user-guide/openclaw/reference/commands).

NemoClaw's platform requirements are separate from quotabot's. Its primary
validated host path is Linux; Apple Silicon macOS and WSL2 have limitations, and
native Windows is not supported. Host-local Ollama evidence does not prove that
the managed inference route selects that runtime or reaches it successfully.
[Prerequisites](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/get-started/prerequisites),
[Local inference](https://docs.nvidia.com/nemoclaw/latest/inference/use-local-inference.html).
