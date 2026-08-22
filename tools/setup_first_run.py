#!/usr/bin/env python3
"""Render conservative first-run guidance from a quotabot JSON snapshot."""

from __future__ import annotations

import json
import math
import re
import sys
import time
from collections.abc import Mapping
from typing import Any

_CLOCK_SKEW_SECONDS = 60
_MAX_RESET_HORIZON_SECONDS = 400 * 24 * 60 * 60
_MEASURED_SOURCE_CLASSES = {
    "authoritative_live",
    "this_machine_fallback",
    "passive_local_evidence",
}
_LOGIN_PROVIDERS = {"claude", "codex", "grok", "antigravity"}
_LOGIN_COMMAND = re.compile(r"\bquotabot login ([a-z0-9_-]{1,64})\b")


def _text(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    parsed = float(value)
    return parsed if math.isfinite(parsed) else None


def _epoch(value: object) -> int | None:
    parsed = _number(value)
    if parsed is None or parsed != math.trunc(parsed):
        return None
    return int(parsed)


def _window_percent(window: Mapping[str, Any]) -> float | None:
    percent = _number(window.get("used_percent"))
    if percent is not None:
        return percent
    used = _number(window.get("used"))
    limit = _number(window.get("limit"))
    if used is None or limit is None or limit <= 0:
        return None
    return used / limit * 100


def _has_current_capture(provider: Mapping[str, Any], now: int) -> bool:
    captured_at = _epoch(provider.get("as_of"))
    return (
        captured_at is not None
        and captured_at > 0
        and captured_at <= now + _CLOCK_SKEW_SECONDS
    )


def _has_current_measured_windows(provider: Mapping[str, Any], now: int) -> bool:
    if _text(provider.get("source_class")) not in _MEASURED_SOURCE_CLASSES:
        return False
    if not _has_current_capture(provider, now):
        return False
    windows = provider.get("windows")
    if not isinstance(windows, list) or not windows:
        return False
    for window in windows:
        if not isinstance(window, Mapping):
            return False
        percent = _window_percent(window)
        if percent is None or percent < 0 or percent > 100:
            return False
        if "resets_at" not in window:
            continue
        resets_at = _epoch(window.get("resets_at"))
        if resets_at is None:
            return False
        if resets_at <= now or resets_at > now + _MAX_RESET_HORIZON_SECONDS:
            return False
    return True


def _is_ready(provider: Mapping[str, Any], now: int) -> bool:
    if provider.get("ok") is not True:
        return False
    if provider.get("stale") is True:
        return False
    if _text(provider.get("suspect")) or _text(provider.get("drift_reason")):
        return False
    if _text(provider.get("error")):
        return False
    kind = _text(provider.get("kind"))
    source_class = _text(provider.get("source_class"))
    if not _has_current_capture(provider, now):
        return False
    if kind == "local":
        models = provider.get("models")
        return (
            source_class == "local_runtime"
            and isinstance(models, list)
            and any(
                isinstance(model, Mapping) and model.get("cloud_offloaded") is not True
                for model in models
            )
        )
    if source_class == "status_only":
        return False
    return _has_current_measured_windows(provider, now)


def _unique(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


def render_first_run(snapshot: object, *, now: int | None = None) -> str:
    """Return first-run guidance, or an empty string for an unusable snapshot."""
    if not isinstance(snapshot, Mapping):
        return ""
    providers = snapshot.get("providers")
    if not isinstance(providers, list) or not providers:
        return ""
    observed_at = int(time.time()) if now is None else now
    grouped: dict[str, list[Mapping[str, object]]] = {}
    for provider in providers:
        if not isinstance(provider, Mapping):
            continue
        key = _text(provider.get("provider"))
        if not key:
            continue
        grouped.setdefault(key, []).append(provider)

    ready: list[str] = []
    login: list[str] = []
    other: list[str] = []

    for key, rows in grouped.items():
        name = _text(rows[0].get("display_name")) or key
        if any(_is_ready(row, observed_at) for row in rows):
            ready.append(name)
            continue
        login_added = False
        for row in rows:
            error = _text(row.get("error"))
            lower_error = error.lower()
            if "invalid" in lower_error and "usage" in lower_error:
                other.append(f"{name} - signed in, quota unreadable: {error}")
                continue
            command = _LOGIN_COMMAND.search(lower_error)
            if command is not None:
                if not login_added:
                    login.append(command.group(1))
                    login_added = True
                continue
            if key in _LOGIN_PROVIDERS and any(
                token in lower_error
                for token in (
                    "token",
                    "login",
                    "auth",
                    "credential",
                    "signed out",
                    "unauthorized",
                )
            ):
                if not login_added:
                    login.append(key)
                    login_added = True
                continue
            if error:
                other.append(f"{name} - {error}")
            elif row.get("ok") is True:
                other.append(f"{name} - no fresh quota evidence")

    ready = _unique(ready)
    login = _unique(login)
    other = _unique(other)
    lines = ["", "First run"]
    if ready:
        lines.append("  Already live (no extra login): " + ", ".join(ready))
    if login:
        lines.append("  Login only if a row is missing or stale on this machine:")
        lines.extend(f"    quotabot login {provider}" for provider in login)
    elif not other:
        lines.append(
            "  No extra login required. Host apps already signed in on this machine are enough."
        )
    lines.extend(f"  {diagnostic}" for diagnostic in other)
    return "\n".join(lines) + "\n"


def main() -> int:
    try:
        snapshot = json.load(sys.stdin)
    except (OSError, ValueError):
        return 0
    sys.stdout.write(render_first_run(snapshot))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
