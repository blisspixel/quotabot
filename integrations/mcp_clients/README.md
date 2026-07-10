# quotabot MCP client snippets

Runnable adoption snippets for using quotabot as a routing MCP server from
Python or TypeScript. They call quota metadata tools only. They do not send
prompts, code, or model requests.

## SDK guidance checked June 29, 2026

- Python: use the stable MCP Python SDK v1 line for production clients and pin
  `mcp>=1.28,<2`. PyPI latest was `1.28.1` when checked.
- TypeScript: use `@modelcontextprotocol/sdk` and the high-level `Client` with
  `StreamableHTTPClientTransport` or `StdioClientTransport`. npm latest was
  `1.29.0` when checked.
- Prefer stdio when the MCP client can spawn quotabot directly. Use Streamable
  HTTP when a host requires HTTP, keeping the endpoint on loopback and enabling
  bearer auth for long-lived processes.
- Treat routing as fail-soft. If quotabot is unavailable, keep the caller's
  original provider or model instead of blocking the request.
- For long-lived routers, subscribe to `quotas://alerts` with standard MCP
  `resources/subscribe`; read the resource after
  `notifications/resources/updated` to receive `quotabot.alerts.v1`.

Sources checked: MCP Python SDK v1.x README and client docs, MCP Python SDK v1.x
`streamable_http.py`, MCP TypeScript SDK v1.x README, client source, and
Streamable HTTP transport source.

## Start quotabot

Stdio snippets spawn the server themselves:

```bash
cd integrations/mcp_clients
python quotabot_mcp_stdio.py
npx tsx quotabot_mcp_stdio.ts
```

Streamable HTTP snippets expect a running loopback server:

```bash
cd collector
dart run bin/mcp_server.dart --http --port 8722 --path /mcp
```

With bearer auth, keep the secret in an environment variable rather than a
literal command argument or an undocumented scratch file:

```bash
cd collector
export QUOTABOT_MCP_TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
dart run bin/mcp_server.dart --http --port 8722 --path /mcp --token-env QUOTABOT_MCP_TOKEN
```

PowerShell:

```powershell
Set-Location collector
$env:QUOTABOT_MCP_TOKEN = python -c "import secrets; print(secrets.token_urlsafe(32))"
dart run bin/mcp_server.dart --http --port 8722 --path /mcp --token-env QUOTABOT_MCP_TOKEN
```

Start the client snippet from a process that inherits the same
`QUOTABOT_MCP_TOKEN`. The token is sent only as an `Authorization: Bearer`
header and is never printed. A token file is also supported for service
managers, but it should live in a private per-user config location with
owner-only permissions, not under the repository.

## Python

Install the stable SDK line:

```bash
python -m pip install "mcp>=1.28,<2" httpx
```

Run:

```bash
python integrations/mcp_clients/quotabot_mcp_http.py
python integrations/mcp_clients/quotabot_mcp_stdio.py
```

Optional environment:

- `QUOTABOT_MCP_URL`: defaults to `http://127.0.0.1:8722/mcp`.
- `QUOTABOT_MCP_TOKEN`: bearer token for Streamable HTTP.
- `QUOTABOT_TASK`: `simple`, `standard`, or `hard`, sent to `suggest_model`.
- `QUOTABOT_COLLECTOR_DIR`: collector directory for stdio. Defaults to this
  repository's `collector/`.
- `DART`: Dart executable. Defaults to `dart`.

## TypeScript

Install the SDK:

```bash
cd integrations/mcp_clients
npm ci
npm run typecheck
```

Run:

```bash
npx tsx quotabot_mcp_http.ts
npx tsx quotabot_mcp_stdio.ts
```

The TypeScript snippets use `.js` import specifiers for local files because that
is the Node ESM convention used by the MCP TypeScript SDK.

## Output

Each snippet prints one small JSON object:

```json
{
  "suggest_schema": "quotabot.suggest.v1",
  "recommended_provider": "claude",
  "headroom_percent": 72,
  "using_local_fallback": false,
  "fallback_provider": "ollama",
  "model_schema": "quotabot.suggest_model.v1",
  "recommended_model": "claude-opus-4-20250514",
  "model_provider": "claude"
}
```

Unknown or unavailable fields are `null`. A nonzero exit means quotabot was not
reachable or did not expose the expected tools, so the caller should use its
original provider or model.
