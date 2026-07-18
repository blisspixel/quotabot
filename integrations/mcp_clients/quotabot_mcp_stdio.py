from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from quotabot_mcp_common import (
    as_pretty_json,
    require_routing_tools,
    routing_summary,
    structured_content,
)


def collector_dir() -> Path:
    configured = os.environ.get("QUOTABOT_COLLECTOR_DIR")
    if configured:
        return Path(configured).expanduser().resolve()
    return Path(__file__).resolve().parents[2] / "collector"


async def main() -> int:
    task = os.environ.get("QUOTABOT_TASK", "standard")
    server = StdioServerParameters(
        command=os.environ.get("DART", "dart"),
        args=["run", "bin/mcp_server.dart"],
        cwd=str(collector_dir()),
    )

    try:
        async with stdio_client(server) as (read_stream, write_stream):
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
