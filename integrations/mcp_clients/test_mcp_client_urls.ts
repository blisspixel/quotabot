import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { requireLoopbackMcpUrl } from "./quotabot_mcp_common.js";

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
