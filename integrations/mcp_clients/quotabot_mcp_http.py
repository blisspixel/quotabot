from __future__ import annotations

import asyncio
import os
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from quotabot_mcp_common import (
    as_pretty_json,
    require_routing_tools,
    routing_summary,
    structured_content,
)

DEFAULT_MCP_URL = "http://127.0.0.1:8722/mcp"


def bearer_headers() -> dict[str, str]:
    token = os.environ.get("QUOTABOT_MCP_TOKEN", "").strip()
    return {"Authorization": f"Bearer {token}"} if token else {}


async def main() -> int:
    url = os.environ.get("QUOTABOT_MCP_URL", DEFAULT_MCP_URL)
    task = os.environ.get("QUOTABOT_TASK", "standard")

    try:
        timeout = httpx.Timeout(10.0, read=60.0)
        async with httpx.AsyncClient(headers=bearer_headers(), timeout=timeout) as client:
            async with streamable_http_client(url, http_client=client) as (
                read_stream,
                write_stream,
                _session_id_callback,
            ):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    require_routing_tools(tool.name for tool in tools.tools)

                    suggestion = structured_content(
                        await session.call_tool("suggest_provider", {})
                    )
                    model = structured_content(
                        await session.call_tool("suggest_model", {"task": task})
                    )
                    print(as_pretty_json(routing_summary(suggestion, model)))
                    return 0
    except Exception as error:
        print(f"quotabot MCP unavailable: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
