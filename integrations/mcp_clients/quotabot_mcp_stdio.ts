import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

import {
  errorMessage,
  printRoutingDecision,
} from "./quotabot_mcp_common.js";

const here = dirname(fileURLToPath(import.meta.url));
const collectorDir =
  process.env.QUOTABOT_COLLECTOR_DIR ?? resolve(here, "..", "..", "collector");

const transport = new StdioClientTransport({
  command: process.env.DART ?? "dart",
  args: ["run", "bin/mcp_server.dart"],
  cwd: collectorDir,
  stderr: "inherit",
});

const client = new Client({
  name: "quotabot-mcp-stdio-example",
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
