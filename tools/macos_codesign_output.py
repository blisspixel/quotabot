#!/usr/bin/env python3
"""Strict parsers for bounded Apple codesign output."""

from __future__ import annotations

import plistlib
import re


_CDHASH = re.compile(r"^[0-9a-f]{40}$")


class MacOSCodeSignOutputError(ValueError):
    """Apple codesign output did not satisfy the requested policy."""


def embedded_entitlements(output: str) -> dict[str, object]:
    """Return the embedded entitlement dictionary from codesign output."""
    start = output.find("<?xml")
    end_marker = "</plist>"
    end = output.find(end_marker, start)
    if start < 0 and end < 0:
        return {}
    if start < 0 or end < 0:
        raise MacOSCodeSignOutputError("entitlements_invalid")
    try:
        value = plistlib.loads(output[start : end + len(end_marker)].encode("utf-8"))
    except (UnicodeError, plistlib.InvalidFileException) as error:
        raise MacOSCodeSignOutputError("entitlements_invalid") from error
    if not isinstance(value, dict):
        raise MacOSCodeSignOutputError("entitlements_invalid")
    return value


def code_directory_details(
    output: str,
    *,
    identity: str | None,
    team_id: str | None,
    expected_identifier: str | None = None,
    require_timestamp: bool = True,
    require_cdhash: bool = True,
) -> str | None:
    """Validate signature-detail lines and return one optional CDHash."""
    lines = {line.strip() for line in output.splitlines() if line.strip()}
    cdhashes = [
        line.removeprefix("CDHash=").lower()
        for line in lines
        if line.startswith("CDHash=")
    ]
    if (
        (team_id is not None and f"TeamIdentifier={team_id}" not in lines)
        or (identity is not None and f"Authority={identity}" not in lines)
        or (
            require_timestamp
            and not any(
                line.startswith("Timestamp=") and line != "Timestamp=none"
                for line in lines
            )
        )
        or not any(
            line.startswith("CodeDirectory ") and "runtime" in line for line in lines
        )
        or (
            expected_identifier is not None
            and f"Identifier={expected_identifier}" not in lines
        )
        or (
            require_cdhash
            and (len(cdhashes) != 1 or _CDHASH.fullmatch(cdhashes[0]) is None)
        )
    ):
        raise MacOSCodeSignOutputError("signature_details_invalid")
    return cdhashes[0] if require_cdhash else None
