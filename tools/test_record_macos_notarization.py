"""Tests for notarization receipts bound to exact signed candidates."""

from __future__ import annotations

import hashlib
import json
import os
import struct
import tempfile
import unittest
from pathlib import Path

from tools import native_code_inventory, record_macos_notarization
from tools.record_macos_notarization import MacOSNotarizationError


SUBMISSION_ID = "2EFE2717-52EF-43A5-96DC-0797E4CA1041"
CDHASH = "a" * 40


def _canonical_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, separators=(",", ":"), sort_keys=True).encode("ascii")
    ).hexdigest()


def _macho64() -> bytes:
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")


def _prepare(root: Path, *, surface: str = "cli") -> dict[str, Path]:
    candidate = root / "candidate"
    if surface == "cli":
        launcher = candidate / "bin" / "quotabot"
        code_path = "bin/quotabot"
    else:
        launcher = candidate / "quotabot.app" / "Contents" / "MacOS" / "quotabot"
        code_path = "quotabot.app/Contents/MacOS/quotabot"
    launcher.parent.mkdir(parents=True)
    launcher.write_bytes(_macho64())
    inventory_value = native_code_inventory.inventory_native_code(
        candidate,
        platform="macos",
        surface=surface,
        architecture="arm64",
    ).to_dict()
    inventory = root / "inventory.json"
    _write_json(inventory, inventory_value)
    directories = [{"path": code_path, "architecture": "arm64", "cdhash": CDHASH}]
    signing = root / "signing.json"
    _write_json(
        signing,
        {
            "schema": "quotabot.macos-signing.v1",
            "ok": True,
            "surface": surface,
            "architecture": "arm64",
            "team_id": "ABCDEFGHIJ",
            "identity_sha256": "b" * 64,
            "unsigned_inventory_sha256": "c" * 64,
            "plan_sha256": "d" * 64,
            "entitlements_sha256": _canonical_sha256({}),
            "target_count": 1 if surface == "cli" else 2,
            "code_directory_count": 1,
            "code_directories": directories,
            "code_directories_sha256": _canonical_sha256(directories),
        },
    )
    artifact = root / "submission.zip"
    artifact.write_bytes(b"exact notarization archive")
    artifact_sha256 = hashlib.sha256(artifact.read_bytes()).hexdigest()
    submission = root / "submission.json"
    _write_json(submission, {"id": SUBMISSION_ID, "status": "Accepted"})
    log = root / "log.json"
    _write_json(
        log,
        {
            "jobId": SUBMISSION_ID,
            "status": "Accepted",
            "archiveFilename": artifact.name,
            "sha256": artifact_sha256,
            "ticketContents": [
                {
                    "path": code_path,
                    "digestAlgorithm": "SHA-256",
                    "cdhash": CDHASH,
                    "arch": "arm64",
                }
            ],
            "issues": None,
        },
    )
    return {
        "artifact": artifact,
        "inventory": inventory,
        "signing": signing,
        "submission": submission,
        "log": log,
    }


def _receipt(
    paths: dict[str, Path],
    *,
    surface: str = "cli",
    archive_inventory: dict[str, object] | None = None,
) -> dict[str, object]:
    inventory_value = (
        json.loads(paths["inventory"].read_text())
        if archive_inventory is None
        else archive_inventory
    )
    return record_macos_notarization.notarization_receipt(
        paths["submission"],
        paths["log"],
        artifact_path=paths["artifact"],
        inventory_path=paths["inventory"],
        signing_receipt_path=paths["signing"],
        surface=surface,
        archive_inventory_loader=lambda _artifact, _surface, _architecture: (
            inventory_value
        ),
    )


class RecordMacOSNotarizationTests(unittest.TestCase):
    def test_accepted_ticket_is_bound_to_archive_inventory_and_code(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = _prepare(Path(directory), surface="desktop")
            receipt = _receipt(paths, surface="desktop")

            self.assertEqual(receipt["schema"], "quotabot.macos-notarization.v1")
            self.assertEqual(receipt["submission_id"], SUBMISSION_ID.lower())
            self.assertEqual(receipt["warning_count"], 0)
            self.assertEqual(receipt["signing_plan_sha256"], "d" * 64)
            self.assertEqual(
                receipt["artifact_sha256"],
                hashlib.sha256(paths["artifact"].read_bytes()).hexdigest(),
            )
            self.assertEqual(receipt["submitted_code_directories"][0]["cdhash"], CDHASH)
            self.assertNotIn("message", receipt)

    def test_accepted_log_with_null_issues_is_an_empty_issue_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            receipt = _receipt(_prepare(Path(directory)))
            self.assertEqual(receipt["issue_count"], 0)
            self.assertEqual(receipt["warning_count"], 0)

    def test_archive_hash_and_ticket_replay_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = _prepare(root)
            paths["artifact"].write_bytes(b"different archive")
            with self.assertRaisesRegex(MacOSNotarizationError, "does not match"):
                _receipt(paths)

            paths = _prepare(root / "fresh")
            log = json.loads(paths["log"].read_text())
            log["ticketContents"][0]["cdhash"] = "e" * 40
            _write_json(paths["log"], log)
            with self.assertRaisesRegex(MacOSNotarizationError, "does not cover"):
                _receipt(paths)

    def test_self_inconsistent_submitted_inventory_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = _prepare(Path(directory))
            inventory = json.loads(paths["inventory"].read_text())
            inventory["candidate_sha256"] = "f" * 64
            _write_json(paths["inventory"], inventory)

            with self.assertRaisesRegex(
                MacOSNotarizationError, "candidate evidence is invalid"
            ):
                _receipt(paths)

    def test_submitted_archive_inventory_mismatch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = _prepare(root)
            candidate = root / "different-candidate"
            launcher = candidate / "bin" / "quotabot"
            launcher.parent.mkdir(parents=True)
            launcher.write_bytes(_macho64())
            (candidate / "unexpected.txt").write_text("different", encoding="ascii")
            different = native_code_inventory.inventory_native_code(
                candidate,
                platform="macos",
                surface="cli",
                architecture="arm64",
            ).to_dict()

            with self.assertRaisesRegex(
                MacOSNotarizationError, "archive payload does not match"
            ):
                _receipt(paths, archive_inventory=different)

    def test_invalid_status_and_error_issue_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = _prepare(root)
            submission = json.loads(paths["submission"].read_text())
            submission["status"] = "Invalid"
            _write_json(paths["submission"], submission)
            with self.assertRaisesRegex(MacOSNotarizationError, "did not accept"):
                _receipt(paths)

            paths = _prepare(root / "fresh")
            log = json.loads(paths["log"].read_text())
            log["issues"] = [{"severity": "error", "message": "secret"}]
            _write_json(paths["log"], log)
            with self.assertRaisesRegex(
                MacOSNotarizationError, "contains an error"
            ) as caught:
                _receipt(paths)
            self.assertNotIn("secret", str(caught.exception))

    def test_evidence_reads_are_bounded_and_reject_links(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = _prepare(root)
            original = record_macos_notarization.MAX_NOTARY_JSON_BYTES
            try:
                record_macos_notarization.MAX_NOTARY_JSON_BYTES = 16
                with self.assertRaisesRegex(MacOSNotarizationError, "invalid"):
                    _receipt(paths)
            finally:
                record_macos_notarization.MAX_NOTARY_JSON_BYTES = original

            if os.name != "nt":
                target = root / "target.json"
                target.write_bytes(paths["submission"].read_bytes())
                paths["submission"].unlink()
                paths["submission"].symlink_to(target)
                with self.assertRaisesRegex(MacOSNotarizationError, "invalid"):
                    _receipt(paths)


if __name__ == "__main__":
    unittest.main()
