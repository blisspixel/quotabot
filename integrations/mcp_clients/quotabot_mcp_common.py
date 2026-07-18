from __future__ import annotations

import json
import math
import re
from collections.abc import Iterable
from typing import Any
from urllib.parse import urlsplit


_REQUIRED_ROUTING_TOOLS = ("suggest_provider", "suggest_model")
_LOOPBACK_MCP_URL_PATTERN = re.compile(
    r"^https?://(?:localhost|127\.0\.0\.1|\[::1\])"
    r"(?::[0-9]+)?(?:[/?][^\s\\#]*)?$",
    re.IGNORECASE,
)
_LOOPBACK_MCP_HOSTS = {"localhost", "127.0.0.1", "::1"}
_LOOPBACK_MCP_URL_ERROR = (
    "QUOTABOT_MCP_URL must use http or https with the exact loopback host "
    "localhost, 127.0.0.1, or ::1"
)


def require_loopback_mcp_url(value: str) -> str:
    """Validate an MCP HTTP endpoint without resolving alternate host forms."""
    if not isinstance(value, str) or not _LOOPBACK_MCP_URL_PATTERN.fullmatch(value):
        raise ValueError(_LOOPBACK_MCP_URL_ERROR)

    try:
        parsed = urlsplit(value)
        parsed.port
    except ValueError as error:
        raise ValueError(_LOOPBACK_MCP_URL_ERROR) from error

    hostname = parsed.hostname
    if (
        parsed.scheme.lower() not in {"http", "https"}
        or hostname is None
        or hostname.lower() not in _LOOPBACK_MCP_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise ValueError(_LOOPBACK_MCP_URL_ERROR)
    return value


def structured_content(result: Any) -> dict[str, Any]:
    """Return structured MCP tool content, falling back to JSON text content."""
    direct = getattr(result, "structuredContent", None)
    if isinstance(direct, dict):
        return direct

    snake_case = getattr(result, "structured_content", None)
    if isinstance(snake_case, dict):
        return snake_case

    for item in getattr(result, "content", ()) or ():
        text = getattr(item, "text", None)
        if not isinstance(text, str):
            continue
        try:
            decoded = json.loads(text)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, dict):
            return decoded

    return {}


def routing_summary(
    suggestion: dict[str, Any],
    model_suggestion: dict[str, Any] | None = None,
) -> dict[str, Any]:
    recommended = _object_value(suggestion.get("recommended"))
    fallback = _object_value(suggestion.get("fallback"))
    model = _object_value((model_suggestion or {}).get("recommended"))

    return {
        "suggest_schema": _string_value(suggestion.get("schema")),
        "recommended_provider": _string_value(recommended.get("provider")),
        "headroom_percent": _number_value(recommended.get("headroom_percent")),
        "using_local_fallback": suggestion.get("using_local_fallback") is True,
        "fallback_provider": _string_value(fallback.get("provider")),
        "model_schema": _string_value((model_suggestion or {}).get("schema")),
        "recommended_model": _string_value(model.get("id")),
        "model_provider": _string_value(model.get("provider")),
    }


def as_pretty_json(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, sort_keys=False, allow_nan=False)


def require_routing_tools(tool_names: Iterable[str]) -> None:
    """Raise a clear error when the server lacks a routing tool we call."""
    available = set(tool_names)
    missing = [name for name in _REQUIRED_ROUTING_TOOLS if name not in available]
    if missing:
        raise RuntimeError(f"quotabot MCP tools missing: {', '.join(missing)}")


def _object_value(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string_value(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _number_value(value: Any) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value
