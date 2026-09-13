#!/usr/bin/env python3
"""Prepare and validate the verified release handoff from CI to its owner."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

if __package__:
    from .check_authorship import message_violations
    from .verify_cli_archive import verify_cli_archive
    from .verify_desktop_archive import verify_desktop_archive
else:
    from check_authorship import message_violations
    from verify_cli_archive import verify_cli_archive
    from verify_desktop_archive import verify_desktop_archive

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ".github/workflows/release.yml"
SCHEMA = "quotabot.release-handoff.v1"
ARCHIVES = (
    "quotabot-darwin-arm64-desktop.zip",
    "quotabot-darwin-arm64.tar.gz",
    "quotabot-linux-arm64.tar.gz",
    "quotabot-linux-x64-desktop.tar.gz",
    "quotabot-linux-x64.tar.gz",
    "quotabot-windows-x64-desktop.zip",
    "quotabot-windows-x64.zip",
)
ASSETS = frozenset(ARCHIVES) | {name + ".sha256" for name in ARCHIVES}


def gh(*arguments: str, payload: object | None = None) -> str:
    command = ["gh", *arguments]
    if payload is not None:
        command.extend(["--input", "-"])
    return subprocess.run(
        command,
        input=None if payload is None else json.dumps(payload),
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
        check=True,
        timeout=300,
    ).stdout


def api(endpoint: str, *, payload: object | None = None) -> object:
    method = "GET" if payload is None else "PATCH"
    return json.loads(gh("api", "--method", method, endpoint, payload=payload))


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def tag_commit(repository: str, tag: str) -> str:
    obj = api(f"repos/{repository}/git/ref/tags/{tag}")["object"]
    for _ in range(8):
        if obj["type"] == "commit" and re.fullmatch(r"[0-9a-f]{40}", obj["sha"]):
            return obj["sha"]
        if obj["type"] != "tag":
            break
        obj = api(f"repos/{repository}/git/tags/{obj['sha']}")["object"]
    raise ValueError("Release tag does not resolve to one commit within eight objects")


def require_current_source(metadata: dict) -> None:
    repository = metadata["repository"]
    source = metadata["source_digest"]
    if api(f"repos/{repository}/commits/main")["sha"] != source:
        raise ValueError("Release must target the current protected main tip")
    if tag_commit(repository, metadata["tag"]) != source:
        raise ValueError("Remote release tag no longer points to the workflow commit")


def validate_metadata(metadata: dict) -> None:
    if metadata.get("schema") != SCHEMA:
        raise ValueError("Invalid release handoff schema")
    for key, pattern in (
        ("repository", r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"),
        ("tag", r"v[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?"),
        ("source_digest", r"[0-9a-f]{40}"),
    ):
        if not isinstance(metadata.get(key), str) or not re.fullmatch(
            pattern, metadata[key]
        ):
            raise ValueError(f"Invalid release {key}")
    for key in ("run_id", "run_attempt"):
        if type(metadata.get(key)) is not int or metadata[key] < 1:
            raise ValueError(f"Invalid release {key}")
    if metadata.get("title") != metadata["tag"]:
        raise ValueError("Release title must match the tag")
    body = metadata.get("body")
    if not isinstance(body, str) or not body.strip() or len(body) > 125_000:
        raise ValueError("Invalid release body")
    if message_violations(body) or re.search(r"(?<!\w)@[\w-]+", body):
        raise ValueError("Release body contains author credit or account mentions")
    previous = metadata.get("previous_tag")
    digest = metadata.get("previous_digest")
    if previous is None:
        if (
            digest is not None
            or metadata.get("initial_release") is not True
            or "-" in metadata["tag"]
        ):
            raise ValueError("Missing previous release requires explicit initial mode")
    elif (
        not isinstance(previous, str)
        or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", previous)
        or previous == metadata["tag"]
        or not isinstance(digest, str)
        or not re.fullmatch(r"[0-9a-f]{40}", digest)
        or metadata.get("initial_release") is not False
    ):
        raise ValueError("Invalid previous release identity")


def prepare(output: Path) -> dict:
    environment = os.environ
    tag = environment["GITHUB_REF_NAME"]
    repository = environment["GITHUB_REPOSITORY"]
    windows = environment["WINDOWS_SIGNING_BACKEND"]
    macos = environment["MACOS_SIGNING_MODE"]
    if windows not in {"unsigned", "azure-artifact-signing"} or macos not in {
        "unsigned",
        "developer-id",
    }:
        raise ValueError("Native signing modes must be explicitly validated")
    windows_status = (
        "Windows: Azure Artifact Signing Public Trust with RFC 3161 SHA-256 timestamping."
        if windows == "azure-artifact-signing"
        else "Windows: unsigned transition artifact. SmartScreen publisher identity is not established."
    )
    macos_status = (
        "macOS: Developer ID signed, hardened, notarized, stapled where supported, and Gatekeeper verified."
        if macos == "developer-id"
        else "macOS: unsigned transition artifact. Developer ID and notarization are not established."
    )
    sections = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8").splitlines()
    start = next(
        (
            index + 1
            for index, line in enumerate(sections)
            if line.startswith(f"## {tag[1:]} - ")
        ),
        None,
    )
    if start is None:
        raise ValueError("CHANGELOG.md has no section for the release tag")
    end = next(
        (
            index
            for index in range(start, len(sections))
            if sections[index].startswith("## ")
        ),
        len(sections),
    )
    notes = "\n".join(sections[start:end]).strip()
    if not notes:
        raise ValueError("Release changelog section is empty")
    releases = json.loads(
        gh("api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100")
    )
    stable = [
        release
        for page in releases
        for release in page
        if not release["draft"] and not release["prerelease"]
    ]
    previous = None
    previous_digest = None
    if stable:
        previous = api(f"repos/{repository}/releases/latest")["tag_name"]
        previous_digest = tag_commit(repository, previous)
    elif environment.get("ALLOW_INITIAL_RELEASE") != "true":
        raise ValueError(
            "No previous stable release; explicit initial-release approval is required"
        )
    metadata = {
        "schema": SCHEMA,
        "repository": repository,
        "tag": tag,
        "source_digest": environment["GITHUB_SHA"],
        "run_id": int(environment["GITHUB_RUN_ID"]),
        "run_attempt": int(environment["GITHUB_RUN_ATTEMPT"]),
        "title": tag,
        "body": f"Native signing status: {windows_status} {macos_status} Checksums and GitHub build provenance remain required. Do not bypass SmartScreen or Gatekeeper.\n\n{notes}",
        "previous_tag": previous,
        "previous_digest": previous_digest,
        "initial_release": previous is None,
    }
    validate_metadata(metadata)
    require_current_source(metadata)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    with Path(environment["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as handle:
        handle.write(
            f"previous_tag={previous or ''}\nprevious_digest={previous_digest or ''}\n"
        )
        for key in (
            "windows_signing_backend",
            "windows_subscriber_eku",
            "macos_signing_mode",
            "macos_developer_identity",
            "macos_team_id",
            "macos_notary_issuer_id",
            "macos_notary_key_id",
        ):
            value = environment.get(key.upper(), "")
            if "\r" in value or "\n" in value:
                raise ValueError("Signing output contains a line break")
            handle.write(f"{key}={value}\n")
    return metadata


def asset_manifest(directory: Path) -> dict:
    entries = {path.name: path for path in directory.iterdir()}
    if set(entries) - {"release-handoff.json"} != ASSETS:
        raise ValueError("Release asset set is incomplete or unexpected")
    for name in ASSETS:
        if entries[name].is_symlink() or not entries[name].is_file():
            raise ValueError("Release assets must be ordinary files")
    for name in ARCHIVES:
        verifier = verify_desktop_archive if "-desktop." in name else verify_cli_archive
        verifier(directory / name)
    return {
        name: {
            "sha256": sha256(directory / name),
            "size": (directory / name).stat().st_size,
        }
        for name in sorted(ASSETS)
    }


def bind_manifest(metadata: dict, directory: Path) -> dict:
    """Bind reused successful build artifacts to the final audit's attempt."""
    expected = {
        "repository": os.environ["GITHUB_REPOSITORY"],
        "tag": os.environ["GITHUB_REF_NAME"],
        "source_digest": os.environ["GITHUB_SHA"],
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
    }
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError("Publication metadata differs from the final audit workflow")
    metadata = {**metadata, "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"])}
    validate_metadata(metadata)
    require_current_source(metadata)
    metadata["assets"] = asset_manifest(directory)
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    metadata_parser = commands.add_parser("prepare")
    metadata_parser.add_argument("--output", type=Path, required=True)
    manifest_parser = commands.add_parser("manifest")
    manifest_parser.add_argument("--metadata", type=Path, required=True)
    manifest_parser.add_argument("--directory", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.command == "prepare":
        prepare(arguments.output)
    else:
        metadata = json.loads(arguments.metadata.read_text(encoding="utf-8"))
        metadata = bind_manifest(metadata, arguments.directory)
        (arguments.directory / "release-handoff.json").write_text(
            json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    main()
