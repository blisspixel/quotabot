import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  mcpBearerHeaders,
  requireLoopbackMcpUrl,
} from "./quotabot_mcp_common.js";

type LoopbackUrlCase = {
  url: string;
  accepted: boolean;
};

const cases = JSON.parse(
  readFileSync(new URL("./mcp_loopback_url_cases.json", import.meta.url), "utf8"),
) as LoopbackUrlCase[];

for (const testCase of cases) {
  if (testCase.accepted) {
    const parsed = requireLoopbackMcpUrl(testCase.url);
    assert.ok(parsed instanceof URL, testCase.url);
  } else {
    assert.throws(
      () => requireLoopbackMcpUrl(testCase.url),
      /exact loopback host/,
      testCase.url,
    );
  }
}

const previousToken = process.env.QUOTABOT_MCP_TOKEN;
try {
  delete process.env.QUOTABOT_MCP_TOKEN;
  assert.throws(() => mcpBearerHeaders(), /at least 32/);
  process.env.QUOTABOT_MCP_TOKEN = "short";
  assert.throws(() => mcpBearerHeaders(), /at least 32/);
  process.env.QUOTABOT_MCP_TOKEN = "a".repeat(32);
  assert.deepEqual(mcpBearerHeaders(), {
    Authorization: `Bearer ${"a".repeat(32)}`,
  });
} finally {
  if (previousToken === undefined) {
    delete process.env.QUOTABOT_MCP_TOKEN;
  } else {
    process.env.QUOTABOT_MCP_TOKEN = previousToken;
  }
}
