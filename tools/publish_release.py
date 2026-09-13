#!/usr/bin/env python3
"""Publish a successful CI release handoff using the repository owner's login."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

if __package__:
    from .release_handoff import (
        ARCHIVES,
        ASSETS,
        ROOT,
        WORKFLOW,
        api,
        asset_manifest,
        gh,
        require_current_source,
        validate_metadata,
    )
else:
    from release_handoff import (
        ARCHIVES,
        ASSETS,
        ROOT,
        WORKFLOW,
        api,
        asset_manifest,
        gh,
        require_current_source,
        validate_metadata,
    )


def require_owner(repository: str) -> str:
    user = api("user")
    owner = repository.split("/", 1)[0]
    if user.get("type") != "User" or user.get("login", "").lower() != owner.lower():
        raise ValueError(
            "Publication requires the repository owner's human GitHub login"
        )
    if api(f"repos/{repository}/immutable-releases").get("enabled") is not True:
        raise ValueError("Immutable releases must be enabled before publication")
    return user["login"]


def require_run(metadata: dict, run_id: int) -> None:
    run = api(f"repos/{metadata['repository']}/actions/runs/{run_id}")
    expected = {
        "id": run_id,
        "run_attempt": metadata["run_attempt"],
        "head_sha": metadata["source_digest"],
        "head_branch": metadata["tag"],
        "event": "push",
        "path": WORKFLOW,
        "status": "completed",
        "conclusion": "success",
    }
    if metadata["run_id"] != run_id or any(
        run.get(key) != value for key, value in expected.items()
    ):
        raise ValueError("Release workflow run does not match the successful handoff")


def find_release(repository: str, tag: str) -> dict | None:
    # Tag lookup is published-only; authenticated listings also include drafts.
    pages = json.loads(
        gh("api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100")
    )
    matching = [
        release for page in pages for release in page if release["tag_name"] == tag
    ]
    if len(matching) > 1:
        raise ValueError("Multiple releases match the tag")
    return matching[0] if matching else None


def verify_provenance(path: Path, metadata: dict) -> None:
    repository = metadata["repository"]
    gh(
        "attestation",
        "verify",
        str(path),
        "--repo",
        repository,
        "--signer-workflow",
        f"{repository}/{WORKFLOW}",
        "--source-ref",
        f"refs/tags/{metadata['tag']}",
        "--source-digest",
        metadata["source_digest"],
        "--deny-self-hosted-runners",
    )


def require_draft(release: dict, metadata: dict, owner: str) -> None:
    expected = {
        "tag_name": metadata["tag"],
        "name": metadata["title"],
        "body": metadata["body"],
        "draft": True,
        "prerelease": "-" in metadata["tag"],
    }
    if (
        type(release.get("id")) is not int
        or release["id"] < 1
        or release.get("author", {}).get("login") != owner
        or any(release.get(key) != value for key, value in expected.items())
    ):
        raise ValueError("Release is not the owner's exact expected draft")


def require_assets(assets: list, metadata: dict, owner: str, *, complete: bool) -> None:
    names = [asset.get("name") for asset in assets]
    if (
        len(names) != len(set(names))
        or set(names) - ASSETS
        or (complete and set(names) != ASSETS)
    ):
        raise ValueError("Draft release asset inventory is incomplete or unexpected")
    for asset in assets:
        expected = metadata["assets"][asset["name"]]
        if (
            type(asset.get("id")) is not int
            or asset["id"] < 1
            or asset.get("state") != "uploaded"
            or asset.get("size") != expected["size"]
            or asset.get("digest") != f"sha256:{expected['sha256']}"
            or asset.get("uploader", {}).get("login") != owner
        ):
            raise ValueError("Draft asset bytes or uploader differ from the handoff")


def inventory_identity(assets: list) -> list:
    return sorted(
        [
            (
                asset["id"],
                asset["name"],
                asset["size"],
                asset["digest"],
                asset.get("updated_at"),
            )
            for asset in assets
        ],
        key=lambda entry: entry[1],
    )


def publish(repository: str, run_id: int, directory: Path) -> str:
    directory = directory.resolve()
    owner = require_owner(repository)
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("Handoff download directory must be empty")
    directory.mkdir(parents=True, exist_ok=True)
    gh(
        "run",
        "download",
        str(run_id),
        "--repo",
        repository,
        "--name",
        "release-handoff",
        "--dir",
        str(directory),
    )
    manifest_path = directory / "release-handoff.json"
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 256 * 1024:
        raise ValueError("Invalid handoff manifest file")
    metadata = json.loads(manifest_path.read_text(encoding="utf-8"))
    validate_metadata(metadata)
    if metadata["repository"] != repository:
        raise ValueError("Handoff repository differs from the requested repository")
    require_run(metadata, run_id)
    require_current_source(metadata)
    checkout = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    ).stdout.strip()
    if checkout != metadata["source_digest"]:
        raise ValueError("Use the exact release source checkout to publish")
    subprocess.run(
        ["git", "diff", "--exit-code", "HEAD", "--"], cwd=ROOT, check=True, timeout=30
    )
    verify_provenance(manifest_path, metadata)
    if asset_manifest(directory) != metadata.get("assets"):
        raise ValueError("Downloaded handoff assets differ from the attested manifest")
    for name in ARCHIVES:
        verify_provenance(directory / name, metadata)

    release = find_release(repository, metadata["tag"])
    if release is None:
        with tempfile.TemporaryDirectory(prefix="quotabot-release-notes-") as temporary:
            notes = Path(temporary) / "notes.md"
            notes.write_text(metadata["body"], encoding="utf-8", newline="\n")
            arguments = [
                "release",
                "create",
                metadata["tag"],
                "--repo",
                repository,
                "--draft",
                "--verify-tag",
                "--title",
                metadata["title"],
                "--notes-file",
                str(notes),
            ]
            if "-" in metadata["tag"]:
                arguments.extend(["--prerelease", "--latest=false"])
            require_current_source(metadata)
            gh(*arguments)
        release = find_release(repository, metadata["tag"])
        if release is None:
            raise ValueError("Created release draft was not found")
    require_draft(release, metadata, owner)
    endpoint = f"repos/{repository}/releases/{release['id']}"
    assets = api(endpoint + "/assets?per_page=100")
    require_assets(assets, metadata, owner, complete=False)
    existing = {asset["name"] for asset in assets}
    for name in sorted(ASSETS - existing):
        gh(
            "release",
            "upload",
            metadata["tag"],
            str(directory / name),
            "--repo",
            repository,
        )
    assets = api(endpoint + "/assets?per_page=100")
    require_assets(assets, metadata, owner, complete=True)
    audited_identity = inventory_identity(assets)
    with tempfile.TemporaryDirectory(prefix="quotabot-release-audit-") as temporary:
        downloaded = Path(temporary)
        for asset in assets:
            with (downloaded / asset["name"]).open("wb") as handle:
                subprocess.run(
                    [
                        "gh",
                        "api",
                        "--allow-escape-sequences",
                        "-H",
                        "Accept: application/octet-stream",
                        f"repos/{repository}/releases/assets/{asset['id']}",
                    ],
                    stdout=handle,
                    check=True,
                    timeout=300,
                )
        if asset_manifest(downloaded) != metadata["assets"]:
            raise ValueError(
                "Freshly downloaded draft assets differ from the verified handoff"
            )
        for name in ARCHIVES:
            verify_provenance(downloaded / name, metadata)
    require_owner(repository)
    require_run(metadata, run_id)
    require_current_source(metadata)
    require_draft(api(endpoint), metadata, owner)
    final_assets = api(endpoint + "/assets?per_page=100")
    require_assets(final_assets, metadata, owner, complete=True)
    if inventory_identity(final_assets) != audited_identity:
        raise ValueError("Draft asset set changed after final audit")
    prerelease = "-" in metadata["tag"]
    api(
        endpoint,
        payload={
            "tag_name": metadata["tag"],
            "target_commitish": metadata["source_digest"],
            "name": metadata["title"],
            "body": metadata["body"],
            "draft": False,
            "prerelease": prerelease,
            "make_latest": "false" if prerelease else "true",
        },
    )
    published = api(endpoint)
    if (
        published.get("draft") is not False
        or published.get("immutable") is not True
        or published.get("tag_name") != metadata["tag"]
        or published.get("name") != metadata["title"]
        or published.get("body") != metadata["body"]
        or published.get("prerelease") is not prerelease
        or published.get("author", {}).get("login") != owner
    ):
        raise ValueError("Published release does not match the immutable owner release")
    latest_id = api(f"repos/{repository}/releases/latest")["id"]
    if not prerelease and latest_id != release["id"]:
        raise ValueError("Published stable release did not become GitHub Latest")
    if prerelease and latest_id == release["id"]:
        raise ValueError("Prerelease unexpectedly replaced GitHub Latest")
    return published["html_url"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="blisspixel/quotabot")
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.run_id < 1:
        parser.error("--run-id must be positive")
    print(publish(arguments.repo, arguments.run_id, arguments.directory))


if __name__ == "__main__":
    main()
