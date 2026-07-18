import type { Client } from "@modelcontextprotocol/sdk/client/index.js";

const REQUIRED_ROUTING_TOOLS = ["suggest_provider", "suggest_model"] as const;

export function mcpBearerHeaders() {
  const token = process.env.QUOTABOT_MCP_TOKEN?.trim();
  return token ? { Authorization: `Bearer ${token}` } : undefined;
}

export function structuredContent(result: unknown): Record<string, unknown> {
  const root = objectValue(result);
  if (isRecord(root.structuredContent)) {
    return root.structuredContent;
  }

  const content = root.content;
  if (!Array.isArray(content)) {
    return {};
  }

  for (const item of content) {
    const record = objectValue(item);
    if (typeof record.text !== "string") {
      continue;
    }
    try {
      const decoded = JSON.parse(record.text);
      if (isRecord(decoded)) {
        return decoded;
      }
    } catch {
      continue;
    }
  }

  return {};
}

export function routingSummary(
  suggestion: Record<string, unknown>,
  modelSuggestion: Record<string, unknown> | undefined = undefined,
) {
  const recommended = objectValue(suggestion.recommended);
  const fallback = objectValue(suggestion.fallback);
  const model = objectValue(modelSuggestion?.recommended);

  return {
    suggest_schema: stringValue(suggestion.schema),
    recommended_provider: stringValue(recommended.provider),
    headroom_percent: numberValue(recommended.headroom_percent),
    using_local_fallback: suggestion.using_local_fallback === true,
    fallback_provider: stringValue(fallback.provider),
    model_schema: stringValue(modelSuggestion?.schema),
    recommended_model: stringValue(model.id),
    model_provider: stringValue(model.provider),
  };
}

export async function printRoutingDecision(
  client: Client,
  modelArguments: Record<string, unknown> = {},
): Promise<void> {
  const tools = await client.listTools();
  const names = new Set(tools.tools.map((tool) => tool.name));
  const missing = REQUIRED_ROUTING_TOOLS.filter((name) => !names.has(name));
  if (missing.length > 0) {
    throw new Error(`quotabot MCP tools missing: ${missing.join(", ")}`);
  }

  const suggestion = structuredContent(
    await client.callTool({ name: "suggest_provider", arguments: {} }),
  );
  const model = structuredContent(
    await client.callTool({ name: "suggest_model", arguments: modelArguments }),
  );
  console.log(JSON.stringify(routingSummary(suggestion, model), null, 2));
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function objectValue(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {};
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
