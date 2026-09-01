"""Fail when quotabot's public release versions disagree."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?"
STABLE_VERSION_LABELS = {
    "README current stable",
    "SECURITY current audited release",
    "AGENTS current stable",
    "docs index current stable",
    "setup current stable",
    "ROADMAP current line",
}


class VersionCheckError(ValueError):
    """A required version marker is missing or inconsistent."""


def _required_match(path: Path, pattern: str, label: str) -> str:
    match = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
    if match is None:
        raise VersionCheckError(f"{label}: version marker not found in {path}")
    return match.group(1)


def release_versions(root: Path) -> tuple[dict[str, str], str]:
    """Return release-facing versions and the Flutter build number."""

    collector = root / "collector"
    app = root / "app"
    source_version = _required_match(
        collector / "pubspec.yaml",
        rf"^version:\s*({VERSION})\s*$",
        "collector pubspec",
    )
    versions = {
        "collector pubspec": source_version,
        "CLI": _required_match(
            collector / "bin" / "collect.dart",
            rf"^const _version = '({VERSION})';$",
            "CLI",
        ),
        "MCP": _required_match(
            collector / "lib" / "mcp.dart",
            rf"^const quotabotMcpVersion = '({VERSION})';$",
            "MCP",
        ),
        "Flutter pubspec": _required_match(
            app / "pubspec.yaml",
            rf"^version:\s*({VERSION})\+[0-9]+\s*$",
            "Flutter pubspec",
        ),
        "Flutter update check": _required_match(
            app / "lib" / "update_check.dart",
            rf"^const String quotabotAppVersion = '({VERSION})';$",
            "Flutter update check",
        ),
        "Flutter displayed build": _required_match(
            app / "lib" / "update_check.dart",
            rf"^const String quotabotAppBuild = '({VERSION})\+[0-9]+';$",
            "Flutter displayed build",
        ),
        "Flutter collector lock": _locked_collector_version(app / "pubspec.lock"),
        "README current stable": _required_match(
            root / "README.md",
            rf"^> \*\*Current stable:\*\* ({VERSION})\.",
            "README current stable",
        ),
        "SECURITY current audited release": _required_match(
            root / "SECURITY.md",
            (
                rf"^  The current audited release is \[v({VERSION})\]"
                r"\(https://github\.com/blisspixel/quotabot/releases/tag/v\1\)\."
            ),
            "SECURITY current audited release",
        ),
        "AGENTS current stable": _required_match(
            root / "AGENTS.md",
            rf"^The current verified stable release is ({VERSION})\.",
            "AGENTS current stable",
        ),
        "docs index current stable": _required_match(
            root / "docs" / "README.md",
            rf"^The current verified stable release is ({VERSION})\.",
            "docs index current stable",
        ),
        "setup current stable": _required_match(
            root / "docs" / "SETUP.md",
            (
                rf"^The current stable release is\n\[v({VERSION})\]"
                r"\(https://github\.com/blisspixel/quotabot/releases/tag/v\1\)\."
            ),
            "setup current stable",
        ),
        "ROADMAP current line": _required_match(
            root / "ROADMAP.md",
            rf"^The current line, \*\*({VERSION})\*\*,",
            "ROADMAP current line",
        ),
        "CHANGELOG latest release": _required_match(
            root / "CHANGELOG.md",
            rf"^## ({VERSION}) - [0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}$",
            "CHANGELOG latest release",
        ),
    }
    candidate_markers = (
        (
            root / "README.md",
            rf"^> \*\*Current release candidate:\*\* ({VERSION})\.",
            "README current candidate",
        ),
        (
            root / "docs" / "README.md",
            rf"^({VERSION})\. The next work in the focused 0\.10\.x",
            "docs index current candidate",
        ),
    )
    if "-" in source_version:
        for path, pattern, label in candidate_markers:
            versions[label] = _required_match(path, pattern, label)
    else:
        for path, pattern, label in candidate_markers:
            if re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE):
                raise VersionCheckError(
                    f"{label}: stable source must not retain a candidate marker"
                )
    build = _required_match(
        app / "pubspec.yaml",
        rf"^version:\s*{VERSION}\+([0-9]+)\s*$",
        "Flutter build number",
    )
    displayed_build = _required_match(
        app / "lib" / "update_check.dart",
        rf"^const String quotabotAppBuild = '{VERSION}\+([0-9]+)';$",
        "Flutter displayed build number",
    )
    if displayed_build != build:
        raise VersionCheckError(
            "Flutter displayed build number "
            f"{displayed_build} does not match Flutter pubspec build number {build}"
        )
    return versions, build


def _locked_collector_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    block = re.search(
        r"^  quotabot_collector:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if block is None:
        raise VersionCheckError(
            f"Flutter collector lock: package block not found in {path}"
        )
    match = re.search(
        rf'^    version: "({VERSION})"$', block.group("body"), re.MULTILINE
    )
    if match is None:
        raise VersionCheckError(
            f"Flutter collector lock: version marker not found in {path}"
        )
    return match.group(1)


def check_release_versions(
    root: Path = ROOT,
    *,
    tag: str | None = None,
) -> tuple[str, str]:
    """Validate every version against collector/pubspec.yaml."""

    versions, build = release_versions(root)
    expected = versions["collector pubspec"]
    source_mismatches = {
        label: value
        for label, value in versions.items()
        if label not in STABLE_VERSION_LABELS and value != expected
    }
    if source_mismatches:
        details = ", ".join(
            f"{label}={value}" for label, value in sorted(source_mismatches.items())
        )
        raise VersionCheckError(f"expected {expected}; mismatched {details}")
    stable_versions = {
        label: value
        for label, value in versions.items()
        if label in STABLE_VERSION_LABELS
    }
    if "-" in expected:
        stable_expected = stable_versions["README current stable"]
        if "-" in stable_expected:
            raise VersionCheckError("README current stable must not name a prerelease")
        stable_mismatches = {
            label: value
            for label, value in stable_versions.items()
            if value != stable_expected
        }
        if stable_mismatches:
            details = ", ".join(
                f"{label}={value}" for label, value in sorted(stable_mismatches.items())
            )
            raise VersionCheckError(
                f"expected stable {stable_expected}; mismatched {details}"
            )
    else:
        stable_mismatches = {
            label: value
            for label, value in stable_versions.items()
            if value != expected
        }
        if stable_mismatches:
            details = ", ".join(
                f"{label}={value}" for label, value in sorted(stable_mismatches.items())
            )
            raise VersionCheckError(f"expected {expected}; mismatched {details}")
    if int(build) <= 0:
        raise VersionCheckError("Flutter build number must be positive")
    if tag is not None and tag != f"v{expected}":
        raise VersionCheckError(
            f"tag {tag!r} does not match source version v{expected}"
        )
    return expected, build


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="check quotabot release version consistency"
    )
    parser.add_argument(
        "--tag",
        help="require an exact v-prefixed tag for the source version",
    )
    args = parser.parse_args(argv)
    try:
        version, build = check_release_versions(tag=args.tag)
    except (OSError, VersionCheckError) as error:
        print(f"release version check failed: {error}", file=sys.stderr)
        return 1
    tag_suffix = f", tag {args.tag}" if args.tag is not None else ""
    print(f"release version: {version} (Flutter build {build}{tag_suffix})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
