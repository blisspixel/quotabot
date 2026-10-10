"""Map quotabot snapshot and suggestion JSON into a redacted display record.

The record is quotabot.omarchy.v1. It is a view for the Omarchy bar widget.
It is not a second router: recommendation fields come from quotabot suggest
JSON, and account windows come from the snapshot. Receipts, model catalogs,
hardware dumps, raw account identifiers, and provider secrets are dropped.
"""

from __future__ import annotations

import hashlib
import hmac
import math
import os
import re
from collections.abc import Mapping
from pathlib import Path

SCHEMA = "quotabot.omarchy.v1"
SNAPSHOT_SCHEMA = "quotabot.v1"
SUGGEST_SCHEMA = "quotabot.suggest.v1"
PLUGIN_ID = "blisspixel.quotabot"
TARGET_CONTRACT = "omarchy-4.0.4"
MAX_ACCOUNTS = 24
MAX_WINDOWS = 8
MAX_TEXT = 180

_PROVIDER_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_PUBLIC_LABEL = re.compile(r"^[A-Za-z][A-Za-z0-9 ._-]{0,31}$")
_SOURCE_CLASS = {
    "authoritative_live",
    "this_machine_fallback",
    "passive_local_evidence",
    "local_runtime",
    "status_only",
    "manual",
}
_ADMISSION = {"allowed", "denied", "unresolved"}
_POLICIES = {"balanced", "local_first", "quota_stretch"}
_FALLBACK_KINDS = {"local", "soonest_reset", "passthrough"}
_READINESS = {"loaded", "cold"}
_DECISION_CODE = re.compile(r"^[a-z0-9_]{1,64}$")
_EMAIL = re.compile(r"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b")
_BEARER = re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/=-]{8,}")
_TOKEN = re.compile(
    r"(?i)\b(?:sk|rk|pk|ghp|github_pat|xox[baprs]|ya29|AIza|AKIA)[-_A-Za-z0-9]{8,}\b"
)
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
_LONG_SECRET = re.compile(r"\b[A-Za-z0-9+/_=-]{40,}\b")

JsonObject = dict[str, object]


def finite_number(value: object) -> float | None:
    """Return a finite real number, rejecting booleans and non-numeric values."""
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    number = float(value)
    if not math.isfinite(number):
        return None
    return number


def epoch_seconds(value: object) -> int | None:
    """Keep quotabot's epoch-second timestamps and drop anything else."""
    number = finite_number(value)
    if number is None or number < 1_000_000_000 or number > 10_000_000_000:
        return None
    return int(number)


def provider_id(value: object) -> str:
    if not isinstance(value, str):
        return "unknown"
    text = value.strip().lower()
    if _PROVIDER_ID.fullmatch(text) is None:
        return "unknown"
    return text


def is_public_label(value: str) -> bool:
    """True for a short display word that is not an account identifier."""
    if _PUBLIC_LABEL.fullmatch(value) is None:
        return False
    lowered = value.casefold()
    blocked = ("credential", "token", "bearer", "secret", "password", "sk-")
    return not any(word in lowered for word in blocked)


def scrub_text(value: str, *, home: Path) -> str:
    """Remove emails, secrets, and home paths from a display string."""
    text = value.replace("\x00", "")
    for raw_home in _home_texts(home):
        if raw_home not in {"", "/", "."}:
            text = text.replace(raw_home, "<home>")
    text = _EMAIL.sub("<redacted>", text)
    text = _BEARER.sub("<redacted>", text)
    text = _TOKEN.sub("<redacted>", text)
    text = _JWT.sub("<redacted>", text)
    text = _LONG_SECRET.sub("<redacted>", text)
    return " ".join(text.split())


def account_label(provider: str, account: object, key: bytes) -> str:
    """Return a stable non-reversible label for a sensitive account value."""
    if not isinstance(account, str) or not account.strip():
        return "unknown"
    text = account.strip()
    if is_public_label(text):
        return text
    digest = hmac.new(
        key,
        f"{provider}\0{text}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return f"account:{digest[:12]}"


def scrub_tree(value: object, *, home: Path) -> object:
    """Scrub every string in a JSON-like tree without changing its shape."""
    if isinstance(value, str):
        return scrub_text(value, home=home)
    if isinstance(value, list):
        return [scrub_tree(item, home=home) for item in value]
    if isinstance(value, dict):
        return {
            str(key): scrub_tree(item, home=home)
            for key, item in value.items()
            if isinstance(key, str)
        }
    return value


def build_display(
    snapshot: object,
    suggestion: object,
    *,
    now: int,
    alias_key: bytes,
    home: Path,
) -> JsonObject:
    """Build a display record from already-parsed quotabot JSON objects."""
    snapshot_object = _object(snapshot)
    suggestion_object = _object(suggestion)
    accounts, truncated = _accounts(snapshot_object, alias_key=alias_key, home=home)
    recommendation = _recommendation(
        suggestion_object,
        alias_key=alias_key,
        home=home,
    )
    policy = suggestion_object.get("routing_policy")
    decision = suggestion_object.get("decision_code")
    source = snapshot_object.get("snapshot_source")
    record: JsonObject = {
        "schema": SCHEMA,
        "target_contract": TARGET_CONTRACT,
        "shell_plugin": PLUGIN_ID,
        "generated_at": now,
        "read_ok": True,
        "read_error": None,
        "read_failed_at": None,
        "snapshot_as_of": epoch_seconds(snapshot_object.get("generated_at")),
        "suggestion_as_of": epoch_seconds(suggestion_object.get("as_of")),
        "snapshot_source": source if source in {"live", "simulation"} else None,
        "routing_policy": policy if policy in _POLICIES else None,
        "decision_code": decision
        if isinstance(decision, str) and _DECISION_CODE.fullmatch(decision)
        else None,
        "reason": _short_text(suggestion_object.get("reason"), home=home),
        "recommendation": recommendation,
        "accounts": accounts,
        "accounts_truncated": truncated,
        "fallback": _fallback(suggestion_object, home=home),
    }
    return _as_object(scrub_tree(record, home=home))


def preserve_failure(
    previous: object,
    message: str,
    *,
    now: int,
    home: Path,
) -> JsonObject:
    """Keep the last display and record a failed read without inventing meters."""
    cleaned = scrub_text(message, home=home)[:MAX_TEXT]
    if (
        isinstance(previous, dict)
        and previous.get("schema") == SCHEMA
        and isinstance(previous.get("accounts"), list)
    ):
        updated = dict(previous)
        updated["generated_at"] = now
        updated["read_ok"] = False
        updated["read_error"] = cleaned or "refresh failed"
        updated["read_failed_at"] = now
        return _as_object(scrub_tree(updated, home=home))
    return {
        "schema": SCHEMA,
        "target_contract": TARGET_CONTRACT,
        "shell_plugin": PLUGIN_ID,
        "generated_at": now,
        "read_ok": False,
        "read_error": cleaned or "refresh failed",
        "read_failed_at": now,
        "snapshot_as_of": None,
        "suggestion_as_of": None,
        "snapshot_source": None,
        "routing_policy": None,
        "decision_code": None,
        "reason": None,
        "recommendation": None,
        "accounts": [],
        "accounts_truncated": False,
        "fallback": None,
    }


def _accounts(
    snapshot: JsonObject,
    *,
    alias_key: bytes,
    home: Path,
) -> tuple[list[JsonObject], bool]:
    raw = snapshot.get("providers")
    if not isinstance(raw, list):
        return [], False
    indexed = [item for item in enumerate(raw) if isinstance(item[1], dict)]
    failed = [item for item in indexed if item[1].get("ok") is False]
    rest = [item for item in indexed if item[1].get("ok") is not False]
    ordered = failed + rest
    truncated = len(ordered) > MAX_ACCOUNTS
    selected = sorted(ordered[:MAX_ACCOUNTS], key=lambda item: item[0])
    return [
        _account(_as_object(item[1]), alias_key=alias_key, home=home)
        for item in selected
    ], truncated


def _account(provider: JsonObject, *, alias_key: bytes, home: Path) -> JsonObject:
    provider_name = provider_id(provider.get("provider"))
    windows, out_of_range, windows_truncated = _windows(provider.get("windows"))
    measured = None if out_of_range else _remaining(windows)
    freshness = _provider_freshness(
        provider,
        measured=measured,
        out_of_range=out_of_range,
    )
    if freshness in {"drift", "unknown"}:
        measured = None
        if out_of_range:
            for row in windows:
                row["used_percent"] = None
    source_class = provider.get("source_class")
    admission = provider.get("request_admission")
    kind = provider.get("kind")
    local = kind == "local"
    readiness = provider.get("local_readiness")
    ok = provider.get("ok") is True
    routable = (
        freshness == "live"
        and ok
        and measured is not None
        and admission not in {"denied", "unresolved"}
        and source_class != "manual"
    )
    return {
        "provider": provider_name,
        "display_name": _short_text(provider.get("display_name"), home=home, limit=40)
        or provider_name,
        "account_label": account_label(
            provider_name,
            provider.get("account"),
            alias_key,
        ),
        "kind": kind if kind in {"subscription", "local"} else None,
        "local": local,
        "local_readiness": readiness if local and readiness in _READINESS else None,
        "plan": _public_or_none(provider.get("plan")),
        "source_class": source_class if source_class in _SOURCE_CLASS else None,
        "request_admission": admission if admission in _ADMISSION else None,
        "ok": ok,
        "headroom_percent": measured,
        "resets_at": _binding_reset(windows),
        "freshness": freshness,
        "routable": routable,
        "drift_reason": _short_text(provider.get("drift_reason"), home=home, limit=80),
        "error": None
        if ok
        else _short_text(provider.get("error"), home=home, limit=MAX_TEXT),
        "windows": windows,
        "windows_truncated": windows_truncated,
        "as_of": epoch_seconds(provider.get("as_of")),
    }


def _windows(value: object) -> tuple[list[JsonObject], bool, bool]:
    if not isinstance(value, list):
        return [], False, False
    rows: list[JsonObject] = []
    invalid = False
    for item in value:
        if not isinstance(item, dict):
            continue
        used, bad = _window_used(item)
        invalid = invalid or bad
        label = item.get("label")
        rows.append(
            {
                "label": label.strip()[:80]
                if isinstance(label, str) and label.strip()
                else "window",
                "used_percent": None if used is None else round(used, 1),
                "resets_at": epoch_seconds(item.get("resets_at")),
            }
        )
    truncated = len(rows) > MAX_WINDOWS
    return rows[:MAX_WINDOWS], invalid, truncated


def _window_used(item: Mapping[str, object]) -> tuple[float | None, bool]:
    if "used_percent" in item and item.get("used_percent") is not None:
        number = finite_number(item.get("used_percent"))
        if number is None or number < 0 or number > 100:
            return None, True
        return number, False
    used = finite_number(item.get("used"))
    limit = finite_number(item.get("limit"))
    if used is None or limit is None or limit <= 0:
        return None, False
    ratio = used / limit * 100.0
    if ratio < 0 or ratio > 100:
        return None, True
    return ratio, False


def _remaining(windows: list[JsonObject]) -> float | None:
    used = [
        number
        for row in windows
        if isinstance((number := finite_number(row.get("used_percent"))), float)
    ]
    if not used:
        return None
    binding = round(max(used), 1)
    if binding < 0 or binding > 100:
        return None
    return round(100.0 - binding, 1)


def _binding_reset(windows: list[JsonObject]) -> int | None:
    candidates: list[tuple[float, int]] = []
    for row in windows:
        used = finite_number(row.get("used_percent"))
        reset = epoch_seconds(row.get("resets_at"))
        if used is None or reset is None:
            continue
        candidates.append((used, reset))
    if not candidates:
        return None
    return max(candidates)[1]


def _provider_freshness(
    provider: JsonObject,
    *,
    measured: float | None,
    out_of_range: bool,
) -> str:
    if isinstance(provider.get("drift_reason"), str) or out_of_range:
        return "drift"
    if provider.get("stale") is True:
        return "stale"
    if provider.get("ok") is not True or measured is None:
        return "unknown"
    return "live"


def _recommendation(
    suggestion: JsonObject,
    *,
    alias_key: bytes,
    home: Path,
) -> JsonObject | None:
    raw = suggestion.get("recommended")
    if not isinstance(raw, dict):
        return None
    candidate = _as_object(raw)
    provider_name = provider_id(candidate.get("provider"))
    effective = _in_range_percent(candidate.get("effective_headroom_percent"))
    reported = _in_range_percent(candidate.get("headroom_percent"))
    drift = isinstance(candidate.get("drift_reason"), str)
    stale = candidate.get("stale") is True
    if drift:
        freshness = "drift"
        effective = None
        reported = None
    elif stale:
        freshness = "stale"
    elif effective is None and reported is None:
        freshness = "unknown"
    else:
        freshness = "live"
    readiness = candidate.get("local_readiness")
    local = candidate.get("local") is True
    available = candidate.get("available") is True and freshness != "drift"
    return {
        "provider": provider_name,
        "account_label": account_label(
            provider_name,
            candidate.get("account"),
            alias_key,
        ),
        "headroom_percent": effective if effective is not None else reported,
        "effective_headroom_percent": effective,
        "resets_at": epoch_seconds(candidate.get("resets_at")),
        "freshness": freshness,
        "local": local,
        "local_readiness": readiness if local and readiness in _READINESS else None,
        "available": available,
        "reason": _short_text(suggestion.get("reason"), home=home),
    }


def _fallback(suggestion: JsonObject, *, home: Path) -> JsonObject | None:
    raw = suggestion.get("fallback")
    if not isinstance(raw, dict):
        return None
    kind = raw.get("kind")
    provider = raw.get("provider")
    return {
        "kind": kind if kind in _FALLBACK_KINDS else None,
        "provider": None
        if provider is None
        else provider_id(provider)
        if isinstance(provider, str)
        else "unknown",
        "resets_at": epoch_seconds(raw.get("resets_at")),
        "local": kind == "local",
        "reason": _short_text(raw.get("reason"), home=home),
    }


def _in_range_percent(value: object) -> float | None:
    number = finite_number(value)
    if number is None or number < 0 or number > 100:
        return None
    return round(number, 1)


def _public_or_none(value: object) -> str | None:
    if not isinstance(value, str) or not is_public_label(value.strip()):
        return None
    return value.strip()


def _short_text(value: object, *, home: Path, limit: int = MAX_TEXT) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    cleaned = scrub_text(value, home=home)
    if not cleaned:
        return None
    return cleaned[:limit]


def _object(value: object) -> JsonObject:
    if isinstance(value, dict):
        return _as_object(value)
    return {}


def _as_object(value: object) -> JsonObject:
    if not isinstance(value, dict):
        return {}
    return {str(key): item for key, item in value.items()}


def _home_texts(home: Path) -> tuple[str, ...]:
    values: list[str] = []
    for candidate in (
        home,
        Path.home(),
        os.environ.get("HOME", ""),
        os.environ.get("USERPROFILE", ""),
    ):
        text = str(candidate).strip()
        if text and text not in values:
            values.append(text)
    return tuple(values)
