from __future__ import annotations

import json
from typing import Any


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
    return json.dumps(value, indent=2, sort_keys=False)


def _object_value(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string_value(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _number_value(value: Any) -> int | float | None:
    return value if isinstance(value, (int, float)) else None
