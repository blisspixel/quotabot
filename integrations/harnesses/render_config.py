"""Print advisory MCP configuration without changing a harness or reading secrets."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
HARNESS_IDS = ("opencode-1", "openclaw", "hermes")
ADVISORY_TOOLS = (
    "decide_now",
    "list_quotas",
    "suggest_provider",
    "check_provider_availability",
    "list_models",
    "suggest_model",
)
MCP_URL = "http://127.0.0.1:8722/mcp"
TOKEN_ENV = "QUOTABOT_MCP_TOKEN"


def existing_file(value: str | Path, label: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"{label} must name an existing file")
    if any(ord(char) < 32 for char in str(path)):
        raise ValueError(f"{label} must not contain control characters")
    if any(marker in str(path) for marker in ("${", "{env:", "{file:")):
        raise ValueError(f"{label} must not contain harness substitution syntax")
    return path


def source_launch(collector: Path, dart: str | None) -> dict[str, Any]:
    directory = collector.expanduser().resolve()
    existing_file(directory / "bin" / "mcp_server.dart", "MCP source")
    existing_file(directory / "pubspec.yaml", "Collector package")
    found = dart if dart is not None else shutil.which("dart")
    if not found:
        raise ValueError("Dart was not found; pass --dart with its executable path")
    executable = existing_file(found, "Dart executable")
    if executable.suffix.lower() in {".bat", ".cmd", ".ps1"}:
        raise ValueError("Pass the SDK's dart.exe directly, not a shell wrapper")
    return {
        "command": str(executable),
        "args": ["run", "--verbosity=error", "bin/mcp_server.dart"],
        "cwd": str(directory),
    }


def render_config(
    harness: str,
    transport: str,
    *,
    collector: Path = ROOT / "collector",
    dart: str | None = None,
    executable: str | None = None,
    quotabot: str | None = None,
) -> dict[str, Any]:
    if harness not in HARNESS_IDS:
        raise ValueError("Unsupported harness configuration")
    if transport not in {"stdio", "http"}:
        raise ValueError("Transport must be stdio or http")
    launch_count = sum(value is not None for value in (dart, executable, quotabot))
    if transport == "http" and launch_count:
        raise ValueError("HTTP configuration does not launch Dart or an executable")
    if launch_count > 1:
        raise ValueError("Choose only one of --dart, --executable, or --quotabot")

    if transport == "http":
        substitution = (
            "{env:" + TOKEN_ENV + "}"
            if harness == "opencode-1"
            else "${" + TOKEN_ENV + "}"
        )
        server: dict[str, Any] = {
            "url": MCP_URL,
            "headers": {"Authorization": "Bearer " + substitution},
        }
    elif executable is not None or quotabot is not None:
        selected = existing_file(
            quotabot if quotabot is not None else executable,
            "quotabot CLI" if quotabot is not None else "Compiled MCP executable",
        )
        if selected.suffix.lower() in {".bat", ".cmd", ".ps1"}:
            raise ValueError("Pass a native executable, not a shell wrapper")
        server = {
            "command": str(selected),
            "args": ["mcp"] if quotabot is not None else [],
        }
    else:
        server = source_launch(collector, dart)

    if harness == "opencode-1":
        server["type"] = "local" if transport == "stdio" else "remote"
        server["enabled"] = True
        server["timeout"] = 30000
        if transport == "stdio":
            server["command"] = [server["command"], *server.pop("args")]
        else:
            server["oauth"] = False
        return {
            "$schema": "https://opencode.ai/config.json",
            "mcp": {"quotabot": server},
            "tools": {
                "quotabot_reserve_provider": False,
                "quotabot_release_provider": False,
            },
        }

    server["tools"] = {"include": list(ADVISORY_TOOLS)}
    if harness == "openclaw":
        server["transport"] = "stdio" if transport == "stdio" else "streamable-http"
        server["connectionTimeoutMs"] = 30000
        server["requestTimeoutMs"] = 30000
        return {"mcp": {"servers": {"quotabot": server}}}

    server["protocol"] = "legacy"
    server["connect_timeout"] = 30
    server["timeout"] = 30
    server["sampling"] = {"enabled": False}
    return {"mcp_servers": {"quotabot": server}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("harness", choices=HARNESS_IDS)
    parser.add_argument("--transport", choices=("stdio", "http"), default="stdio")
    parser.add_argument("--collector-dir", type=Path, default=ROOT / "collector")
    parser.add_argument(
        "--dart", help="Existing native Dart executable for source launch"
    )
    parser.add_argument(
        "--executable", help="Existing compiled MCP executable; keep its bundle intact"
    )
    parser.add_argument(
        "--quotabot",
        help="Existing native quotabot 0.11.0+ CLI with the mcp subcommand",
    )
    args = parser.parse_args(argv)
    try:
        result = render_config(
            args.harness,
            args.transport,
            collector=args.collector_dir,
            dart=args.dart,
            executable=args.executable,
            quotabot=args.quotabot,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
