from __future__ import annotations

import json
import math
import re
from collections.abc import Iterable
from typing import TypedDict
from urllib.parse import urlsplit


_REQUIRED_ROUTING_TOOLS = ("suggest_provider", "suggest_model")
_LOOPBACK_MCP_URL_PATTERN = re.compile(
    r"^https?://(?:localhost|127\.0\.0\.1|\[::1\])"
    r"(?::[0-9]+)?(?:[/?][^\s\\#]*)?$",
    re.IGNORECASE,
)
_LOOPBACK_MCP_HOSTS = {"localhost", "127.0.0.1", "::1"}
_MIN_MCP_BEARER_TOKEN_CHARACTERS = 32
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
        port = parsed.port
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
        or port == 0
    ):
        raise ValueError(_LOOPBACK_MCP_URL_ERROR)
    return value


def require_mcp_bearer_token(value: str | None) -> str:
    """Require the minimum token shape enforced by the HTTP server."""
    token = value.strip() if isinstance(value, str) else ""
    if len(token) < _MIN_MCP_BEARER_TOKEN_CHARACTERS:
        raise ValueError(
            "QUOTABOT_MCP_TOKEN must contain at least "
            f"{_MIN_MCP_BEARER_TOKEN_CHARACTERS} characters"
        )
    return token


def structured_content(result: object) -> dict[str, object]:
    """Return structured MCP tool content, falling back to JSON text content."""
    direct: object = getattr(result, "structuredContent", None)
    if isinstance(direct, dict):
        return _object_value(direct)

    snake_case: object = getattr(result, "structured_content", None)
    if isinstance(snake_case, dict):
        return _object_value(snake_case)

    content: object = getattr(result, "content", None)
    if not isinstance(content, (list, tuple)):
        return {}
    for item in content:
        text: object = getattr(item, "text", None)
        if not isinstance(text, str):
            continue
        try:
            decoded: object = json.loads(text)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, dict):
            return _object_value(decoded)

    return {}


class RoutingSummary(TypedDict):
    suggest_schema: str | None
    recommended_provider: str | None
    headroom_percent: int | float | None
    using_local_fallback: bool
    fallback_provider: str | None
    model_schema: str | None
    recommended_model: str | None
    model_provider: str | None


def routing_summary(
    suggestion: dict[str, object],
    model_suggestion: dict[str, object] | None = None,
) -> RoutingSummary:
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


def as_pretty_json(value: object) -> str:
    return json.dumps(value, indent=2, sort_keys=False, allow_nan=False)


def require_routing_tools(tool_names: Iterable[str]) -> None:
    """Raise a clear error when the server lacks a routing tool we call."""
    available = set(tool_names)
    missing = [name for name in _REQUIRED_ROUTING_TOOLS if name not in available]
    if missing:
        raise RuntimeError(f"quotabot MCP tools missing: {', '.join(missing)}")


def _object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    return {key: item for key, item in value.items() if isinstance(key, str)}


def _string_value(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def _number_value(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value
