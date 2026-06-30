import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

import {
  errorMessage,
  mcpBearerHeaders,
  printRoutingDecision,
} from "./quotabot_mcp_common.js";

const url = process.env.QUOTABOT_MCP_URL ?? "http://127.0.0.1:8722/mcp";
const headers = mcpBearerHeaders();
const transport = new StreamableHTTPClientTransport(
  new URL(url),
  headers ? { requestInit: { headers } } : undefined,
);

const client = new Client({
  name: "quotabot-mcp-http-example",
  version: "1.0.0",
});

try {
  await client.connect(transport);
  await printRoutingDecision(client, {
    task: process.env.QUOTABOT_TASK ?? "standard",
  });
} catch (error) {
  console.error(`quotabot MCP unavailable: ${errorMessage(error)}`);
  process.exitCode = 1;
} finally {
  await client.close().catch(() => undefined);
}
