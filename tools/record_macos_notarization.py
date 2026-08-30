#!/usr/bin/env python3
"""Bind Apple notarization acceptance to one exact signed macOS candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.native_code_inventory import (  # noqa: E402
    NativeInventoryError,
    inventory_native_code,
    load_inventory_manifest,
)
from tools.sign_macos_candidate import (  # noqa: E402
    MacOSSigningError,
    load_macos_signing_receipt,
)
from tools.validate_macos_signing_delta import (  # noqa: E402
    MacOSSigningDeltaError,
    validated_macos_inventory,
)


SCHEMA = "quotabot.macos-notarization.v1"
ERROR_SCHEMA = "quotabot.macos-notarization-error.v1"
MAX_NOTARY_JSON_BYTES = 1024 * 1024
MAX_RECEIPT_BYTES = 128 * 1024
MAX_ARTIFACT_BYTES = 2 * 1024 * 1024 * 1024
_SUBMISSION_ID = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_CDHASH = re.compile(r"^[0-9a-f]{40}$")


class MacOSNotarizationError(ValueError):
    """A bounded notarization-result failure."""


def _read_json(path: Path) -> tuple[dict[str, object], bytes]:
    descriptor = -1
    try:
        metadata = path.lstat()
        if (
            path.is_symlink()
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > MAX_NOTARY_JSON_BYTES
        ):
            raise MacOSNotarizationError("notarization evidence is invalid")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_size != metadata.st_size
            or opened.st_mtime_ns != metadata.st_mtime_ns
            or (metadata.st_dev and opened.st_dev != metadata.st_dev)
            or (metadata.st_ino and opened.st_ino != metadata.st_ino)
        ):
            raise MacOSNotarizationError("notarization evidence is invalid")
        payload = bytearray()
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise MacOSNotarizationError("notarization evidence is invalid")
            payload.extend(chunk)
            remaining -= len(chunk)
        extra = os.read(descriptor, 1)
        after = os.fstat(descriptor)
        if (
            extra
            or not stat.S_ISREG(after.st_mode)
            or after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
            or (opened.st_dev and after.st_dev != opened.st_dev)
            or (opened.st_ino and after.st_ino != opened.st_ino)
        ):
            raise MacOSNotarizationError("notarization evidence is invalid")
        value = json.loads(bytes(payload).decode("utf-8"))
    except MacOSNotarizationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MacOSNotarizationError("notarization evidence is invalid") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(value, dict):
        raise MacOSNotarizationError("notarization evidence is invalid")
    return value, bytes(payload)


def _hash_artifact(path: Path) -> str:
    descriptor = -1
    try:
        metadata = path.lstat()
        if (
            path.is_symlink()
            or not stat.S_ISREG(metadata.st_mode)
            or not 0 < metadata.st_size <= MAX_ARTIFACT_BYTES
        ):
            raise MacOSNotarizationError("notarization artifact is invalid")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (
            opened.st_size != metadata.st_size
            or opened.st_mtime_ns != metadata.st_mtime_ns
            or (metadata.st_dev and opened.st_dev != metadata.st_dev)
            or (metadata.st_ino and opened.st_ino != metadata.st_ino)
        ):
            raise MacOSNotarizationError("notarization artifact is invalid")
        digest = hashlib.sha256()
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise MacOSNotarizationError("notarization artifact is invalid")
            digest.update(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        if (
            os.read(descriptor, 1)
            or after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
        ):
            raise MacOSNotarizationError("notarization artifact is invalid")
        return digest.hexdigest()
    except MacOSNotarizationError:
        raise
    except OSError as error:
        raise MacOSNotarizationError("notarization artifact is invalid") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _canonical_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
        ).encode("ascii")
    ).hexdigest()


def _inventory_notarization_archive(
    artifact_path: Path,
    surface: str,
    architecture: str,
    *,
    ditto_path: Path = Path("/usr/bin/ditto"),
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, object]:
    try:
        metadata = ditto_path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or not os.access(ditto_path, os.X_OK):
            raise MacOSNotarizationError("archive extractor is unavailable")
        with tempfile.TemporaryDirectory(prefix="quotabot-notary-") as directory:
            expanded = Path(directory)
            completed = runner(
                [str(ditto_path), "-x", "-k", str(artifact_path), str(expanded)],
                check=False,
                capture_output=True,
                text=True,
                timeout=180,
                env=os.environ.copy(),
            )
            output = f"{completed.stdout}\n{completed.stderr}"
            if completed.returncode != 0 or len(output) > 256 * 1024:
                raise MacOSNotarizationError("notarization archive is invalid")
            expected_name = "candidate" if surface == "cli" else "quotabot.app"
            entries = list(expanded.iterdir())
            if len(entries) != 1 or entries[0].name != expected_name:
                raise MacOSNotarizationError("notarization archive is invalid")
            candidate = expanded / "candidate" if surface == "cli" else expanded
            return inventory_native_code(
                candidate,
                platform="macos",
                surface=surface,
                architecture=architecture,
            ).to_dict()
    except MacOSNotarizationError:
        raise
    except (NativeInventoryError, OSError, subprocess.SubprocessError) as error:
        raise MacOSNotarizationError("notarization archive is invalid") from error


def notarization_receipt(
    submission_path: Path,
    log_path: Path,
    *,
    artifact_path: Path,
    inventory_path: Path,
    signing_receipt_path: Path,
    surface: str,
    archive_inventory_loader: Callable[
        [Path, str, str], dict[str, object]
    ] = _inventory_notarization_archive,
) -> dict[str, object]:
    if surface not in {"cli", "desktop"}:
        raise MacOSNotarizationError("notarization surface is invalid")
    submission, submission_bytes = _read_json(submission_path)
    log, log_bytes = _read_json(log_path)
    artifact_sha256 = _hash_artifact(artifact_path)
    try:
        inventory = validated_macos_inventory(load_inventory_manifest(inventory_path))
        signing = load_macos_signing_receipt(signing_receipt_path, surface=surface)
        archive_inventory = validated_macos_inventory(
            archive_inventory_loader(
                artifact_path,
                surface,
                str(signing["architecture"]),
            )
        )
        if _hash_artifact(artifact_path) != artifact_sha256:
            raise MacOSNotarizationError(
                "notarization artifact changed during validation"
            )
    except (
        NativeInventoryError,
        MacOSSigningDeltaError,
        MacOSSigningError,
        OSError,
    ) as error:
        raise MacOSNotarizationError(
            "submitted candidate evidence is invalid"
        ) from error
    except MacOSNotarizationError:
        raise
    if (
        inventory.get("platform") != "macos"
        or inventory.get("surface") != surface
        or inventory.get("architecture") != signing.get("architecture")
        or not isinstance(inventory.get("candidate_sha256"), str)
        or _SHA256.fullmatch(str(inventory["candidate_sha256"])) is None
        or not isinstance(inventory.get("inventory_sha256"), str)
        or _SHA256.fullmatch(str(inventory["inventory_sha256"])) is None
        or archive_inventory != inventory
    ):
        raise MacOSNotarizationError("submitted archive payload does not match")

    submission_id = submission.get("id")
    if (
        not isinstance(submission_id, str)
        or _SUBMISSION_ID.fullmatch(submission_id) is None
        or log.get("jobId") != submission_id
        or submission.get("status") != "Accepted"
        or log.get("status") != "Accepted"
    ):
        raise MacOSNotarizationError("Apple did not accept the notarization")
    apple_sha256 = str(log.get("sha256", "")).lower()
    if (
        _SHA256.fullmatch(apple_sha256) is None
        or apple_sha256 != artifact_sha256
        or log.get("archiveFilename") != artifact_path.name
    ):
        raise MacOSNotarizationError("Apple notarization artifact does not match")

    issues_value = log.get("issues")
    issues = [] if issues_value is None else issues_value
    if not isinstance(issues, list) or len(issues) > 1024:
        raise MacOSNotarizationError("notarization issue list is invalid")
    warning_count = 0
    for issue in issues:
        if not isinstance(issue, dict):
            raise MacOSNotarizationError("notarization issue list is invalid")
        severity = issue.get("severity")
        if severity == "error":
            raise MacOSNotarizationError("notarization contains an error")
        if severity == "warning":
            warning_count += 1
        elif severity not in {None, "info"}:
            raise MacOSNotarizationError("notarization issue severity is invalid")

    ticket_contents = log.get("ticketContents")
    if (
        not isinstance(ticket_contents, list)
        or not ticket_contents
        or len(ticket_contents) > 4096
    ):
        raise MacOSNotarizationError("notarization ticket is invalid")
    apple_code_directories: set[tuple[str, str]] = set()
    for ticket in ticket_contents:
        if not isinstance(ticket, dict):
            raise MacOSNotarizationError("notarization ticket is invalid")
        architecture = ticket.get("arch")
        cdhash = str(ticket.get("cdhash", "")).lower()
        if (
            ticket.get("digestAlgorithm") != "SHA-256"
            or architecture not in {"x86_64", "arm64"}
            or _CDHASH.fullmatch(cdhash) is None
            or not isinstance(ticket.get("path"), str)
            or not ticket["path"]
        ):
            raise MacOSNotarizationError("notarization ticket is invalid")
        apple_code_directories.add((str(architecture), cdhash))
    signed_directories = signing["code_directories"]
    assert isinstance(signed_directories, list)
    for entry in signed_directories:
        assert isinstance(entry, dict)
        if (
            str(entry["architecture"]),
            str(entry["cdhash"]),
        ) not in apple_code_directories:
            raise MacOSNotarizationError(
                "notarization ticket does not cover the candidate"
            )

    return {
        "schema": SCHEMA,
        "ok": True,
        "surface": surface,
        "architecture": signing["architecture"],
        "submission_id": submission_id.lower(),
        "status": "accepted",
        "issue_count": len(issues),
        "warning_count": warning_count,
        "artifact_sha256": artifact_sha256,
        "submitted_candidate_sha256": inventory["candidate_sha256"],
        "submitted_inventory_sha256": inventory["inventory_sha256"],
        "submitted_code_directories": signed_directories,
        "submitted_code_directories_sha256": signing["code_directories_sha256"],
        "signing_plan_sha256": signing["plan_sha256"],
        "entitlements_sha256": signing["entitlements_sha256"],
        "ticket_count": len(ticket_contents),
        "ticket_sha256": _canonical_sha256(ticket_contents),
        "submission_response_sha256": hashlib.sha256(submission_bytes).hexdigest(),
        "log_response_sha256": hashlib.sha256(log_bytes).hexdigest(),
    }


def load_notarization_receipt(path: Path, *, surface: str) -> dict[str, object]:
    value, _payload = _read_json(path)
    directories = value.get("submitted_code_directories")
    digest_fields = (
        "artifact_sha256",
        "submitted_candidate_sha256",
        "submitted_inventory_sha256",
        "submitted_code_directories_sha256",
        "signing_plan_sha256",
        "entitlements_sha256",
        "ticket_sha256",
        "submission_response_sha256",
        "log_response_sha256",
    )
    if (
        value.get("schema") != SCHEMA
        or value.get("ok") is not True
        or value.get("surface") != surface
        or value.get("architecture") not in {"x64", "arm64"}
        or value.get("status") != "accepted"
        or not isinstance(value.get("submission_id"), str)
        or _SUBMISSION_ID.fullmatch(str(value["submission_id"])) is None
        or not isinstance(value.get("issue_count"), int)
        or isinstance(value.get("issue_count"), bool)
        or not 0 <= int(value["issue_count"]) <= 1024
        or not isinstance(value.get("warning_count"), int)
        or isinstance(value.get("warning_count"), bool)
        or not 0 <= int(value["warning_count"]) <= int(value["issue_count"])
        or not isinstance(value.get("ticket_count"), int)
        or isinstance(value.get("ticket_count"), bool)
        or not 1 <= int(value["ticket_count"]) <= 4096
        or not isinstance(directories, list)
        or not directories
        or len(directories) > 1024
        or any(
            not isinstance(value.get(field), str)
            or _SHA256.fullmatch(str(value[field])) is None
            for field in digest_fields
        )
        or _canonical_sha256(directories)
        != value.get("submitted_code_directories_sha256")
    ):
        raise MacOSNotarizationError("notarization receipt is invalid")
    seen: set[tuple[str, str]] = set()
    for entry in directories:
        if not isinstance(entry, dict):
            raise MacOSNotarizationError("notarization receipt is invalid")
        key = (str(entry.get("path", "")), str(entry.get("architecture", "")))
        if (
            not key[0]
            or key[1] not in {"x86_64", "arm64"}
            or _CDHASH.fullmatch(str(entry.get("cdhash", ""))) is None
            or key in seen
        ):
            raise MacOSNotarizationError("notarization receipt is invalid")
        seen.add(key)
    if directories != sorted(
        directories, key=lambda item: (str(item["path"]), str(item["architecture"]))
    ):
        raise MacOSNotarizationError("notarization receipt is invalid")
    return value


def _publish_receipt(path: Path, receipt: dict[str, object]) -> None:
    payload = (
        json.dumps(receipt, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("ascii")
    if len(payload) > MAX_RECEIPT_BYTES:
        raise MacOSNotarizationError("notarization receipt is too large")
    descriptor = -1
    temporary: Path | None = None
    try:
        parent = path.parent.resolve(strict=True)
        if path.name in {"", ".", ".."} or path.is_symlink():
            raise MacOSNotarizationError("notarization receipt path is invalid")
        if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
            raise MacOSNotarizationError("notarization receipt path is invalid")
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=parent
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, parent / path.name)
        temporary = None
    except MacOSNotarizationError:
        raise
    except OSError as error:
        raise MacOSNotarizationError(
            "notarization receipt could not be saved"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate Apple notarization JSON against one exact candidate."
    )
    parser.add_argument("--submission", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--signing-receipt", required=True, type=Path)
    parser.add_argument("--surface", required=True, choices=("cli", "desktop"))
    parser.add_argument("--receipt", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(sys.argv[1:] if argv is None else argv)
    try:
        receipt = notarization_receipt(
            args.submission,
            args.log,
            artifact_path=args.artifact,
            inventory_path=args.inventory,
            signing_receipt_path=args.signing_receipt,
            surface=args.surface,
        )
        _publish_receipt(args.receipt, receipt)
    except MacOSNotarizationError as error:
        print(
            json.dumps(
                {"schema": ERROR_SCHEMA, "ok": False, "error": str(error)},
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 1
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "ok": True,
                "surface": args.surface,
                "submission_id": receipt["submission_id"],
                "warning_count": receipt["warning_count"],
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
