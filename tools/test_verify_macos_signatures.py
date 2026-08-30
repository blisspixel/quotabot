"""Tests for exact macOS Developer ID verification receipts."""

from __future__ import annotations

import hashlib
import io
import json
import plistlib
import struct
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools import (
    create_macos_signing_plan,
    native_code_inventory,
    verify_macos_signatures,
)
from tools.verify_macos_signatures import MacOSSignatureVerificationError


IDENTITY = "Developer ID Application: Example Publisher (ABCDEFGHIJ)"
TEAM_ID = "ABCDEFGHIJ"
SUBMISSION_ID = "2efe2717-52ef-43a5-96dc-0797e4ca1041"
CDHASH = "a" * 40


def _canonical_sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, separators=(",", ":"), sort_keys=True).encode("ascii")
    ).hexdigest()


def _macho64() -> bytes:
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)


def _write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def _prepare(base: Path, *, surface: str):
    root = base / "candidate"
    if surface == "cli":
        _write(root / "bin" / "quotabot", _macho64())
        _write(root / "lib" / "libsqlite3.dylib", _macho64())
        code_paths = ("bin/quotabot", "lib/libsqlite3.dylib")
        expected_entitlements = None
        entitlement_value: dict[str, object] = {}
    else:
        _write(
            root / "quotabot.app" / "Contents" / "MacOS" / "quotabot",
            _macho64(),
        )
        _write(
            root
            / "quotabot.app"
            / "Contents"
            / "Frameworks"
            / "Example.framework"
            / "Versions"
            / "A"
            / "Example",
            _macho64(),
        )
        code_paths = (
            "quotabot.app/Contents/Frameworks/Example.framework/Versions/A/Example",
            "quotabot.app/Contents/MacOS/quotabot",
        )
        entitlement_value = {"com.example.read-only": True}
        expected_entitlements = base / "DeveloperID.entitlements"
        expected_entitlements.write_bytes(plistlib.dumps(entitlement_value))
    inventory = native_code_inventory.inventory_native_code(
        root,
        platform="macos",
        surface=surface,
        architecture="arm64",
    ).to_dict()
    manifest = base / "inventory.json"
    manifest.write_text(json.dumps(inventory), encoding="utf-8")
    plan_value = create_macos_signing_plan.signing_plan_from_inventory(inventory)
    plan = base / "signing-plan.json"
    plan.write_text(
        json.dumps(plan_value, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="ascii",
    )
    plan_sha256 = create_macos_signing_plan.canonical_macos_signing_plan_sha256(
        plan_value
    )
    directories = [
        {"path": path, "architecture": "arm64", "cdhash": CDHASH}
        for path in sorted(code_paths)
    ]
    notarization = base / "notarization.json"
    notarization.write_text(
        json.dumps(
            {
                "schema": "quotabot.macos-notarization.v1",
                "ok": True,
                "surface": surface,
                "architecture": "arm64",
                "submission_id": SUBMISSION_ID,
                "status": "accepted",
                "issue_count": 0,
                "warning_count": 0,
                "artifact_sha256": "a" * 64,
                "submitted_candidate_sha256": inventory["candidate_sha256"],
                "submitted_inventory_sha256": inventory["inventory_sha256"],
                "submitted_code_directories": directories,
                "submitted_code_directories_sha256": _canonical_sha256(directories),
                "signing_plan_sha256": plan_sha256,
                "entitlements_sha256": _canonical_sha256(entitlement_value),
                "ticket_count": len(directories),
                "ticket_sha256": "b" * 64,
                "submission_response_sha256": "c" * 64,
                "log_response_sha256": "d" * 64,
            }
        ),
        encoding="utf-8",
    )
    stapling_delta = None
    if surface == "desktop":
        stapling_delta = base / "stapling-delta.json"
        stapling_delta.write_text(
            json.dumps(
                {
                    "schema": "quotabot.macos-signing-delta.v1",
                    "ok": True,
                    "operation": "stapling",
                    "surface": "desktop",
                    "architecture": "arm64",
                    "before_candidate_sha256": inventory["candidate_sha256"],
                    "after_candidate_sha256": inventory["candidate_sha256"],
                    "before_inventory_sha256": inventory["inventory_sha256"],
                    "after_inventory_sha256": inventory["inventory_sha256"],
                    "plan_sha256": plan_sha256,
                    "planned_native_count": len(code_paths),
                    "changed_native_count": 0,
                    "signature_metadata_change_count": 0,
                    "added_signature_metadata_count": 0,
                },
                separators=(",", ":"),
                sort_keys=True,
            ),
            encoding="ascii",
        )
    tools = {}
    for name in ("codesign", "spctl", "xcrun"):
        path = base / name
        path.write_bytes(b"tool")
        tools[name] = path
    return (
        root,
        manifest,
        plan,
        notarization,
        stapling_delta,
        expected_entitlements,
        entitlement_value,
        tools,
    )


def _details(*, cli_primary: bool = False) -> str:
    lines = [
        "CodeDirectory v=20500 flags=0x10000(runtime)",
        f"Authority={IDENTITY}",
        "Timestamp=Aug 30, 2026 at 12:00:00 PM",
        f"TeamIdentifier={TEAM_ID}",
        f"CDHash={CDHASH}",
    ]
    if cli_primary:
        lines.append("Identifier=io.quotabot.cli")
    return "\n".join(lines)


def _runner(
    commands: list[list[str]],
    *,
    entitlement_value: dict[str, object],
    gatekeeper_source: str = "Notarized Developer ID",
):
    def runner(command, **_kwargs):
        commands.append(command)
        if "--entitlements" in command:
            if command[-1].endswith("quotabot.app"):
                return subprocess.CompletedProcess(
                    command, 0, plistlib.dumps(entitlement_value).decode("utf-8"), ""
                )
            return subprocess.CompletedProcess(command, 0, "", "")
        if "--display" in command:
            normalized = command[-1].replace("\\", "/")
            return subprocess.CompletedProcess(
                command,
                0,
                _details(cli_primary=normalized.endswith("bin/quotabot")),
                "",
            )
        if "--assess" in command:
            return subprocess.CompletedProcess(
                command, 0, f"accepted\nsource={gatekeeper_source}", ""
            )
        return subprocess.CompletedProcess(command, 0, "accepted", "")

    return runner


def _verify_prepared(
    prepared,
    *,
    receipt_path: Path,
    runner,
):
    root, manifest, plan, notarization, delta, entitlements, _value, tools = prepared
    surface = "desktop" if entitlements is not None else "cli"
    return verify_macos_signatures.verify_macos_signatures(
        root,
        manifest_path=manifest,
        signing_plan_path=plan,
        notarization_receipt_path=notarization,
        stapling_delta_receipt_path=delta,
        surface=surface,
        architecture="arm64",
        expected_identity=IDENTITY,
        expected_team_id=TEAM_ID,
        expected_entitlements_path=entitlements,
        receipt_path=receipt_path,
        codesign_path=tools["codesign"],
        spctl_path=tools["spctl"],
        xcrun_path=tools["xcrun"],
        runner=runner,
    )


class VerifyMacOSSignaturesTests(unittest.TestCase):
    def test_cli_verifies_every_target_and_notarized_gatekeeper_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, plan, notarization, delta, entitlements, value, tools = (
                _prepare(base, surface="cli")
            )
            receipt = base / "receipt.json"
            commands: list[list[str]] = []

            result = verify_macos_signatures.verify_macos_signatures(
                root,
                manifest_path=manifest,
                signing_plan_path=plan,
                notarization_receipt_path=notarization,
                stapling_delta_receipt_path=delta,
                surface="cli",
                architecture="arm64",
                expected_identity=IDENTITY,
                expected_team_id=TEAM_ID,
                expected_entitlements_path=entitlements,
                receipt_path=receipt,
                codesign_path=tools["codesign"],
                spctl_path=tools["spctl"],
                xcrun_path=tools["xcrun"],
                runner=_runner(commands, entitlement_value=value),
            )

            self.assertEqual(result["verified_target_count"], 2)
            self.assertEqual(result["gatekeeper_source"], "Notarized Developer ID")
            self.assertFalse(result["staple_valid"])
            self.assertFalse(any("stapler" in command for command in commands))
            self.assertEqual(json.loads(receipt.read_text())["ok"], True)

    def test_desktop_verifies_entitlements_deep_bundle_and_staple(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, plan, notarization, delta, entitlements, value, tools = (
                _prepare(base, surface="desktop")
            )
            receipt = base / "receipt.json"
            commands: list[list[str]] = []

            result = verify_macos_signatures.verify_macos_signatures(
                root,
                manifest_path=manifest,
                signing_plan_path=plan,
                notarization_receipt_path=notarization,
                stapling_delta_receipt_path=delta,
                surface="desktop",
                architecture="arm64",
                expected_identity=IDENTITY,
                expected_team_id=TEAM_ID,
                expected_entitlements_path=entitlements,
                receipt_path=receipt,
                codesign_path=tools["codesign"],
                spctl_path=tools["spctl"],
                xcrun_path=tools["xcrun"],
                runner=_runner(commands, entitlement_value=value),
            )

            self.assertTrue(result["staple_valid"])
            self.assertTrue(
                any(
                    "--verify" in command and "--deep" in command
                    for command in commands
                )
            )
            self.assertTrue(any("stapler" in command for command in commands))

    def test_nonnotarized_gatekeeper_and_entitlement_mismatch_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            prepared = _prepare(base, surface="desktop")
            root, manifest, plan, notarization, delta, entitlements, value, tools = (
                prepared
            )
            receipt = base / "receipt.json"
            with self.assertRaises(MacOSSignatureVerificationError) as caught:
                verify_macos_signatures.verify_macos_signatures(
                    root,
                    manifest_path=manifest,
                    signing_plan_path=plan,
                    notarization_receipt_path=notarization,
                    stapling_delta_receipt_path=delta,
                    surface="desktop",
                    architecture="arm64",
                    expected_identity=IDENTITY,
                    expected_team_id=TEAM_ID,
                    expected_entitlements_path=entitlements,
                    receipt_path=receipt,
                    codesign_path=tools["codesign"],
                    spctl_path=tools["spctl"],
                    xcrun_path=tools["xcrun"],
                    runner=_runner(
                        [], entitlement_value=value, gatekeeper_source="Developer ID"
                    ),
                )
            self.assertEqual(caught.exception.code, "gatekeeper_notarization_failed")

            prepared = _prepare(base / "fresh", surface="desktop")
            root, manifest, plan, notarization, delta, entitlements, _value, tools = (
                prepared
            )
            with self.assertRaises(MacOSSignatureVerificationError) as caught:
                verify_macos_signatures.verify_macos_signatures(
                    root,
                    manifest_path=manifest,
                    signing_plan_path=plan,
                    notarization_receipt_path=notarization,
                    stapling_delta_receipt_path=delta,
                    surface="desktop",
                    architecture="arm64",
                    expected_identity=IDENTITY,
                    expected_team_id=TEAM_ID,
                    expected_entitlements_path=entitlements,
                    receipt_path=base / "fresh" / "receipt.json",
                    codesign_path=tools["codesign"],
                    spctl_path=tools["spctl"],
                    xcrun_path=tools["xcrun"],
                    runner=_runner([], entitlement_value={"unexpected": True}),
                )
            self.assertEqual(caught.exception.code, "entitlements_verification_failed")

    def test_wrong_identity_and_replayed_code_directory_fail_without_leak(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, manifest, plan, notarization, delta, entitlements, value, tools = (
                _prepare(base, surface="cli")
            )
            receipt = base / "receipt.json"

            def wrong_identity(command, **_kwargs):
                completed = _runner([], entitlement_value=value)(command, **_kwargs)
                return subprocess.CompletedProcess(
                    command,
                    completed.returncode,
                    completed.stdout.replace(
                        f"Authority={IDENTITY}", "Authority=Wrong"
                    ),
                    completed.stderr,
                )

            with self.assertRaises(MacOSSignatureVerificationError) as caught:
                verify_macos_signatures.verify_macos_signatures(
                    root,
                    manifest_path=manifest,
                    signing_plan_path=plan,
                    notarization_receipt_path=notarization,
                    stapling_delta_receipt_path=delta,
                    surface="cli",
                    architecture="arm64",
                    expected_identity=IDENTITY,
                    expected_team_id=TEAM_ID,
                    expected_entitlements_path=entitlements,
                    receipt_path=receipt,
                    codesign_path=tools["codesign"],
                    spctl_path=tools["spctl"],
                    xcrun_path=tools["xcrun"],
                    runner=wrong_identity,
                )
            self.assertEqual(caught.exception.code, "signature_policy_failed")
            self.assertNotIn("Wrong", str(caught.exception))

            replay = json.loads(notarization.read_text())
            replay["submitted_code_directories"][0]["cdhash"] = "e" * 40
            replay["submitted_code_directories_sha256"] = _canonical_sha256(
                replay["submitted_code_directories"]
            )
            notarization.write_text(json.dumps(replay), encoding="utf-8")
            with self.assertRaises(MacOSSignatureVerificationError) as caught:
                verify_macos_signatures.verify_macos_signatures(
                    root,
                    manifest_path=manifest,
                    signing_plan_path=plan,
                    notarization_receipt_path=notarization,
                    stapling_delta_receipt_path=delta,
                    surface="cli",
                    architecture="arm64",
                    expected_identity=IDENTITY,
                    expected_team_id=TEAM_ID,
                    expected_entitlements_path=entitlements,
                    receipt_path=receipt,
                    codesign_path=tools["codesign"],
                    spctl_path=tools["spctl"],
                    xcrun_path=tools["xcrun"],
                    runner=_runner([], entitlement_value=value),
                )
            self.assertEqual(caught.exception.code, "notarization_binding_failed")

    def test_tampered_plan_and_stapling_delta_break_the_evidence_chain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            prepared = _prepare(base / "plan", surface="desktop")
            notarization = prepared[3]
            value = prepared[6]
            notarization_value = json.loads(notarization.read_text(encoding="utf-8"))
            notarization_value["signing_plan_sha256"] = "e" * 64
            notarization.write_text(json.dumps(notarization_value), encoding="utf-8")

            with self.assertRaises(MacOSSignatureVerificationError) as caught:
                _verify_prepared(
                    prepared,
                    receipt_path=base / "plan" / "receipt.json",
                    runner=_runner([], entitlement_value=value),
                )
            self.assertEqual(caught.exception.code, "candidate_validation_failed")

            prepared = _prepare(base / "delta", surface="desktop")
            delta = prepared[4]
            value = prepared[6]
            assert delta is not None
            delta_value = json.loads(delta.read_text(encoding="utf-8"))
            delta_value["after_inventory_sha256"] = "e" * 64
            delta.write_text(json.dumps(delta_value), encoding="utf-8")

            with self.assertRaises(MacOSSignatureVerificationError) as caught:
                _verify_prepared(
                    prepared,
                    receipt_path=base / "delta" / "receipt.json",
                    runner=_runner([], entitlement_value=value),
                )
            self.assertEqual(caught.exception.code, "notarization_binding_failed")

    def test_native_tool_failures_and_timeouts_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)

            for name, surface, failure, expected_code in (
                ("codesign", "cli", "codesign", "codesign_verify_failed"),
                ("gatekeeper", "cli", "spctl", "gatekeeper_assessment_failed"),
                ("stapler", "desktop", "stapler", "staple_validation_failed"),
                ("timeout", "cli", "timeout", "codesign_verify_failed"),
            ):
                prepared = _prepare(base / name, surface=surface)
                value = prepared[6]
                normal_runner = _runner([], entitlement_value=value)

                def failing_runner(command, **kwargs):
                    if failure == "timeout" and "--verify" in command:
                        raise subprocess.TimeoutExpired(command, 180)
                    if failure == "codesign" and "--verify" in command:
                        return subprocess.CompletedProcess(command, 1, "", "failed")
                    if failure == "spctl" and "--assess" in command:
                        return subprocess.CompletedProcess(command, 1, "", "failed")
                    if failure == "stapler" and "stapler" in command:
                        return subprocess.CompletedProcess(command, 1, "", "failed")
                    return normal_runner(command, **kwargs)

                with self.assertRaises(MacOSSignatureVerificationError) as caught:
                    _verify_prepared(
                        prepared,
                        receipt_path=base / name / "receipt.json",
                        runner=failing_runner,
                    )
                self.assertEqual(caught.exception.code, expected_code)

    def test_cli_reports_failure_receipt_publish_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            output = io.StringIO()

            with (
                mock.patch.object(
                    verify_macos_signatures,
                    "verify_macos_signatures",
                    side_effect=MacOSSignatureVerificationError(
                        "candidate_validation_failed"
                    ),
                ),
                redirect_stdout(output),
            ):
                result = verify_macos_signatures.main(
                    [
                        "--manifest",
                        str(base / "missing-inventory.json"),
                        "--signing-plan",
                        str(base / "missing-plan.json"),
                        "--notarization-receipt",
                        str(base / "missing-notarization.json"),
                        "--surface",
                        "cli",
                        "--architecture",
                        "arm64",
                        "--expected-identity",
                        IDENTITY,
                        "--expected-team-id",
                        TEAM_ID,
                        "--receipt",
                        str(base),
                        str(base / "missing-candidate"),
                    ]
                )

            self.assertEqual(result, 1)
            failure = json.loads(output.getvalue())
            self.assertEqual(failure["code"], "candidate_validation_failed")
            self.assertEqual(failure["receipt_error_code"], "receipt_path_invalid")


if __name__ == "__main__":
    unittest.main()
