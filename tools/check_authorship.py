"""Check first-party commit and tag identities and attribution metadata."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LEGACY_REFS_PATH = ROOT / "tools" / "legacy_release_refs.json"
# Add another human identity only after explicit maintainer review.
HUMAN_IDENTITIES = frozenset(
    {("Nick Seal", "32712898+blisspixel@users.noreply.github.com")}
)
GITHUB_COMMITTER = ("GitHub", "noreply@github.com")
IDENTITY = re.compile(r"(.+) <([^<>]+)> -?[0-9]+ [+-][0-9]{4}")
TRAILER = re.compile(
    r"^[ \t]*(?:[-*>][ \t]+)?(?:"
    r"Co-Authored-By|Signed-Off-By|Reviewed-By|Tested-By|Acked-By|"
    r"Helped-By|Assisted-By|Generated-By|Generated-With|AI-Generated|"
    r"Claude-Session|Codex-Session|Session-Id|Trace-Id"
    r")[ \t]*:",
    re.IGNORECASE | re.MULTILINE,
)
AI_CREDIT = re.compile(
    r"^[ \t]*(?:[-*>][ \t]+)?[\[*_]*(?:"
    r"generated (?:with|by)|made by|authored by|written by|assisted by|"
    r"implemented by|created by|thanks to|by"
    r")[ \t]+[\[*_]*(?:"
    r"Claude(?: Code)?|Codex|ChatGPT|GitHub Copilot|Copilot|Cursor|"
    r"Gemini|Grok|Kiro|OpenAI|Anthropic|(?:an? )?AI(?: assistant| model| tool)?"
    r")\b",
    re.IGNORECASE | re.MULTILINE,
)


class AuthorshipError(ValueError):
    """The Git metadata is unavailable, incomplete, or violates policy."""


def git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "--no-replace-objects", *arguments],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=30,
        check=False,
    )
    if result.returncode:
        raise AuthorshipError("could not read the required Git metadata")
    return result.stdout


def identity(headers: str, role: str) -> tuple[str, str]:
    values = [
        line[len(role) + 1 :]
        for line in headers.splitlines()
        if line.startswith(role + " ")
    ]
    if len(values) != 1:
        raise AuthorshipError(f"expected exactly one {role} identity")
    match = IDENTITY.fullmatch(values[0])
    if match is None:
        raise AuthorshipError(f"invalid {role} identity")
    return match.group(1), match.group(2)


def message_violations(message: str) -> list[str]:
    violations = []
    if TRAILER.search(message):
        violations.append("attribution or session trailer")
    if AI_CREDIT.search(message):
        violations.append("assistant credit marker")
    return violations


def object_violations(raw: str, object_type: str) -> list[str]:
    headers, separator, message = raw.partition("\n\n")
    if not separator:
        raise AuthorshipError("Git object has no message boundary")
    violations = message_violations(message)
    if object_type == "commit":
        if identity(headers, "author") not in HUMAN_IDENTITIES:
            violations.append("unapproved author identity")
        if identity(headers, "committer") not in HUMAN_IDENTITIES | {GITHUB_COMMITTER}:
            violations.append("unapproved committer identity")
    elif object_type == "tag":
        if [line for line in headers.splitlines() if line.startswith("type ")] != [
            "type commit"
        ]:
            violations.append("annotated tag must point directly to a commit")
        if identity(headers, "tagger") not in HUMAN_IDENTITIES:
            violations.append("unapproved tagger identity")
    else:
        raise AuthorshipError("unsupported Git object type")
    return violations


def load_legacy_refs() -> dict[str, tuple[str, str]]:
    """Load reviewed tag pins from this tooling, never the inspected checkout."""
    try:
        baseline = json.loads(LEGACY_REFS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise AuthorshipError(
            "could not read the historical release ref baseline"
        ) from error
    if (
        not isinstance(baseline, dict)
        or baseline.get("schema") != "quotabot.legacy-release-refs.v1"
        or baseline.get("repository") != "blisspixel/quotabot"
        or not isinstance(baseline.get("refs"), list)
    ):
        raise AuthorshipError("invalid historical release ref baseline")
    refs = {}
    for row in baseline["refs"]:
        if (
            not isinstance(row, dict)
            or set(row) != {"name", "object_type", "object_id"}
            or not isinstance(row["name"], str)
            or not re.fullmatch(r"refs/tags/v[0-9A-Za-z._-]+", row["name"])
            or row["name"] in refs
            or row["object_type"] not in ("commit", "tag")
            or not isinstance(row["object_id"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", row["object_id"])
        ):
            raise AuthorshipError("invalid or duplicate historical release ref pin")
        refs[row["name"]] = (row["object_type"], row["object_id"])
    return refs


def check_repository(
    root: Path, *, legacy_refs: dict[str, tuple[str, str]] | None = None
) -> tuple[int, int, list[str]]:
    # Explicit injection exists for isolated graph tests; the CLI cannot replace
    # the canonical baseline with policy supplied by its target checkout.
    legacy_refs = load_legacy_refs() if legacy_refs is None else legacy_refs
    if git(root, "rev-parse", "--is-shallow-repository").strip() != "false":
        raise AuthorshipError("fetch complete branch and tag history before checking")
    refs = [
        tuple(row.split(" "))
        for row in git(
            root, "for-each-ref", "--format=%(refname) %(objecttype) %(objectname)"
        ).splitlines()
    ]
    historical = {
        name for name, kind, oid in refs if legacy_refs.get(name) == (kind, oid)
    }
    # Traverse every other ref independently. Subtracting legacy ancestry from
    # --all would wrongly hide an old commit reintroduced on main or a new ref.
    active_refs = ["HEAD", *(name for name, _, _ in refs if name not in historical)]
    commits = git(root, "rev-list", *active_refs, "--").splitlines()
    if not commits:
        raise AuthorshipError("no committed history to check")
    failures = []
    for commit in commits:
        raw = git(root, "cat-file", "commit", commit)
        for violation in object_violations(raw, "commit"):
            failures.append(f"commit {commit}: {violation}")
    tag_count = 0
    pinned_objects = {oid for _, oid in legacy_refs.values()}
    for name, object_type, object_id in refs:
        is_tag_ref = name.startswith("refs/tags/")
        if not is_tag_ref and object_type != "tag":
            continue
        tag_count += int(is_tag_ref)
        if name in historical:
            continue
        if name in legacy_refs:
            failures.append(f"tag {name}: historical release ref differs from its pin")
        elif object_id in pinned_objects:
            failures.append(
                f"tag {name}: historical release object requires its pinned name"
            )
        if object_type != "tag":
            failures.append(f"tag object {object_id}: annotated human tagger required")
            continue
        raw = git(root, "cat-file", "tag", object_id)
        for violation in object_violations(raw, "tag"):
            failures.append(f"tag object {object_id}: {violation}")
    return len(commits), tag_count, failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        commits, tags, failures = check_repository(args.repo)
    except (AuthorshipError, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        print(f"authorship check failed: {error}", file=sys.stderr)
        return 1
    if failures:
        for failure in failures[:20]:
            print(f"authorship check failed: {failure}", file=sys.stderr)
        if len(failures) > 20:
            print(f"{len(failures)} total authorship violations", file=sys.stderr)
        return 1
    print(f"authorship check passed: {commits} active-history commits, {tags} tags")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
