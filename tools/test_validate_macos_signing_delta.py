"""Tests for macOS signing and stapling inventory-delta validation."""

from __future__ import annotations

import hashlib
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tools.create_macos_signing_plan import signing_plan_from_inventory
from tools.native_code_inventory import canonical_sha256
from tools.validate_macos_signing_delta import (
    ERROR_SCHEMA,
    SCHEMA,
    MacOSSigningDeltaError,
    main,
    validate_macos_signing_delta,
)


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("ascii")).hexdigest()


def _directory(path: str, *, mode: int = 0o755) -> dict[str, object]:
    return {"path": path, "kind": "directory", "mode": mode}


def _file(
    path: str,
    label: str,
    *,
    size: int = 32,
    mode: int = 0o644,
) -> dict[str, object]:
    return {
        "path": path,
        "kind": "file",
        "bytes": size,
        "mode": mode,
        "sha256": _digest(label),
    }


def _inventory(
    entries: list[dict[str, object]],
    native_paths: list[str],
    *,
    surface: str,
) -> dict[str, object]:
    ordered_entries = sorted(entries, key=lambda entry: str(entry["path"]))
    files = {
        str(entry["path"]): entry
        for entry in ordered_entries
        if entry["kind"] == "file"
    }
    native_code = []
    for path in sorted(native_paths):
        entry = files[path]
        native_code.append(
            {
                "path": path,
                "kind": "macho",
                "architecture": "arm64",
                "bytes": entry["bytes"],
                "sha256": entry["sha256"],
            }
        )
    body: dict[str, object] = {
        "schema": "quotabot.signing-inventory.v1",
        "platform": "macos",
        "surface": surface,
        "architecture": "arm64",
        "candidate_file_count": len(files),
        "candidate_bytes": sum(int(entry["bytes"]) for entry in files.values()),
        "candidate_sha256": canonical_sha256(ordered_entries),
        "candidate_entry_count": len(ordered_entries),
        "candidate_entries": ordered_entries,
        "native_code_count": len(native_code),
        "native_code": native_code,
    }
    return {**body, "inventory_sha256": canonical_sha256(body)}


def _publish(path: Path, value: dict[str, object]) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n",
        encoding="ascii",
    )


def _cli_inventory(*, executable_label: str, readme_label: str = "readme") -> dict:
    return _inventory(
        [
            _directory("bin"),
            _file("bin/quotabot", executable_label, mode=0o755),
            _directory("lib"),
            _file("lib/libsqlite3.dylib", f"library-{executable_label}"),
            _file("README.txt", readme_label),
        ],
        ["bin/quotabot", "lib/libsqlite3.dylib"],
        surface="cli",
    )


def _desktop_inventory(
    *,
    executable_label: str,
    signature_label: str | None = None,
) -> dict:
    entries = [
        _directory("quotabot.app"),
        _directory("quotabot.app/Contents"),
        _file("quotabot.app/Contents/Info.plist", "info"),
        _directory("quotabot.app/Contents/MacOS"),
        _file(
            "quotabot.app/Contents/MacOS/quotabot",
            executable_label,
            mode=0o755,
        ),
    ]
    if signature_label is not None:
        entries.extend(
            [
                _directory("quotabot.app/Contents/_CodeSignature"),
                _file(
                    "quotabot.app/Contents/_CodeSignature/CodeResources",
                    signature_label,
                ),
            ]
        )
    return _inventory(
        entries,
        ["quotabot.app/Contents/MacOS/quotabot"],
        surface="desktop",
    )


class MacOSSigningDeltaTests(unittest.TestCase):
    def _paths(
        self,
        base: Path,
        before: dict,
        after: dict,
        *,
        plan_inventory: dict | None = None,
    ) -> tuple[Path, Path, Path]:
        before_path = base / "before.json"
        after_path = base / "after.json"
        plan_path = base / "plan.json"
        _publish(before_path, before)
        _publish(after_path, after)
        _publish(plan_path, signing_plan_from_inventory(plan_inventory or before))
        return before_path, after_path, plan_path

    def test_cli_signing_requires_every_exact_planned_macho_to_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            before = _cli_inventory(executable_label="unsigned")
            after = _cli_inventory(executable_label="signed")
            paths = self._paths(base, before, after)

            receipt = validate_macos_signing_delta(*paths, operation="signing")

            self.assertEqual(receipt["schema"], SCHEMA)
            self.assertEqual(receipt["planned_native_count"], 2)
            self.assertEqual(receipt["changed_native_count"], 2)
            self.assertEqual(receipt["signature_metadata_change_count"], 0)

            one_unchanged = _inventory(
                [
                    _directory("bin"),
                    _file("bin/quotabot", "signed", mode=0o755),
                    _directory("lib"),
                    _file("lib/libsqlite3.dylib", "library-unsigned"),
                    _file("README.txt", "readme"),
                ],
                ["bin/quotabot", "lib/libsqlite3.dylib"],
                surface="cli",
            )
            unchanged_paths = self._paths(base, before, one_unchanged)
            with self.assertRaisesRegex(
                MacOSSigningDeltaError, "planned_native_unchanged"
            ):
                validate_macos_signing_delta(
                    *unchanged_paths,
                    operation="signing",
                )

    def test_desktop_signing_allows_only_inventoried_bundle_signature_metadata(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            before = _desktop_inventory(executable_label="unsigned")
            after = _desktop_inventory(
                executable_label="signed",
                signature_label="code-resources",
            )
            paths = self._paths(base, before, after)

            receipt = validate_macos_signing_delta(*paths, operation="signing")

            self.assertEqual(receipt["changed_native_count"], 1)
            self.assertEqual(receipt["signature_metadata_change_count"], 2)
            self.assertEqual(receipt["added_signature_metadata_count"], 2)

            outside = _desktop_inventory(executable_label="signed")
            outside["candidate_entries"].append(
                _file("quotabot.app/Contents/unplanned.txt", "unplanned")
            )
            outside = _inventory(
                outside["candidate_entries"],
                ["quotabot.app/Contents/MacOS/quotabot"],
                surface="desktop",
            )
            outside_paths = self._paths(base, before, outside)
            with self.assertRaisesRegex(
                MacOSSigningDeltaError,
                "path_added_outside_signature_metadata",
            ):
                validate_macos_signing_delta(*outside_paths, operation="signing")

    def test_nonplanned_changes_removals_kind_changes_and_modes_fail_closed(
        self,
    ) -> None:
        before = _cli_inventory(executable_label="unsigned")
        cases: list[tuple[str, dict, str]] = []

        changed_content = _cli_inventory(
            executable_label="signed", readme_label="changed"
        )
        cases.append(("content", changed_content, "content_changed_outside_plan"))

        removed = _inventory(
            [
                entry
                for entry in _cli_inventory(executable_label="signed")[
                    "candidate_entries"
                ]
                if entry["path"] != "README.txt"
            ],
            ["bin/quotabot", "lib/libsqlite3.dylib"],
            surface="cli",
        )
        cases.append(("removed", removed, "path_removed"))

        kind_entries = _cli_inventory(executable_label="signed")["candidate_entries"]
        kind_changed = [
            _directory("README.txt") if entry["path"] == "README.txt" else entry
            for entry in kind_entries
        ]
        cases.append(
            (
                "kind",
                _inventory(
                    kind_changed,
                    ["bin/quotabot", "lib/libsqlite3.dylib"],
                    surface="cli",
                ),
                "kind_changed",
            )
        )

        mode_entries = _cli_inventory(executable_label="signed")["candidate_entries"]
        mode_changed = [
            _file("bin/quotabot", "signed", mode=0o700)
            if entry["path"] == "bin/quotabot"
            else entry
            for entry in mode_entries
        ]
        cases.append(
            (
                "mode",
                _inventory(
                    mode_changed,
                    ["bin/quotabot", "lib/libsqlite3.dylib"],
                    surface="cli",
                ),
                "mode_changed",
            )
        )

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for label, after, code in cases:
                with self.subTest(label=label):
                    paths = self._paths(base, before, after)
                    with self.assertRaisesRegex(MacOSSigningDeltaError, code):
                        validate_macos_signing_delta(*paths, operation="signing")

    def test_stapling_preserves_native_code_and_changes_only_signature_metadata(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            unsigned = _desktop_inventory(executable_label="unsigned")
            signed = _desktop_inventory(
                executable_label="signed",
                signature_label="signed-resources",
            )
            stapled = _desktop_inventory(
                executable_label="signed",
                signature_label="stapled-resources",
            )
            paths = self._paths(
                base,
                signed,
                stapled,
                plan_inventory=unsigned,
            )

            receipt = validate_macos_signing_delta(*paths, operation="stapling")

            self.assertEqual(receipt["changed_native_count"], 0)
            self.assertEqual(receipt["signature_metadata_change_count"], 1)

            native_changed = _desktop_inventory(
                executable_label="restapled-binary",
                signature_label="stapled-resources",
            )
            changed_paths = self._paths(
                base,
                signed,
                native_changed,
                plan_inventory=unsigned,
            )
            with self.assertRaisesRegex(
                MacOSSigningDeltaError, "native_changed_during_stapling"
            ):
                validate_macos_signing_delta(*changed_paths, operation="stapling")

            unchanged_paths = self._paths(
                base,
                signed,
                signed,
                plan_inventory=unsigned,
            )
            unchanged_receipt = validate_macos_signing_delta(
                *unchanged_paths, operation="stapling"
            )
            self.assertEqual(unchanged_receipt["changed_native_count"], 0)
            self.assertEqual(unchanged_receipt["signature_metadata_change_count"], 0)

    def test_cli_publishes_bounded_atomic_success_and_failure_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            before = _cli_inventory(executable_label="unsigned")
            after = _cli_inventory(executable_label="signed")
            before_path, after_path, plan_path = self._paths(base, before, after)
            receipt_path = base / "receipt.json"
            receipt_path.write_text("old", encoding="ascii")

            with redirect_stdout(io.StringIO()):
                result = main(
                    [
                        "--unsigned",
                        str(before_path),
                        "--signed",
                        str(after_path),
                        "--plan",
                        str(plan_path),
                        "--operation",
                        "signing",
                        "--receipt",
                        str(receipt_path),
                    ]
                )

            self.assertEqual(result, 0)
            success = json.loads(receipt_path.read_text(encoding="ascii"))
            self.assertEqual(success["schema"], SCHEMA)
            self.assertLess(receipt_path.stat().st_size, 128 * 1024)
            self.assertFalse(
                any(
                    child.name.startswith(f".{receipt_path.name}.")
                    for child in base.iterdir()
                )
            )

            invalid_after = _cli_inventory(
                executable_label="signed", readme_label="tampered"
            )
            _publish(after_path, invalid_after)
            with redirect_stdout(io.StringIO()):
                failure_result = main(
                    [
                        "--before",
                        str(before_path),
                        "--after",
                        str(after_path),
                        "--plan",
                        str(plan_path),
                        "--operation",
                        "signing",
                        "--receipt",
                        str(receipt_path),
                    ]
                )
            self.assertEqual(failure_result, 1)
            failure = json.loads(receipt_path.read_text(encoding="ascii"))
            self.assertEqual(failure["schema"], ERROR_SCHEMA)
            self.assertEqual(failure["code"], "content_changed_outside_plan")

    def test_cli_reports_failure_receipt_publish_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            output = io.StringIO()

            with redirect_stdout(output):
                result = main(
                    [
                        "--before",
                        str(base / "missing-before.json"),
                        "--after",
                        str(base / "missing-after.json"),
                        "--plan",
                        str(base / "missing-plan.json"),
                        "--operation",
                        "signing",
                        "--receipt",
                        str(base),
                    ]
                )

            self.assertEqual(result, 1)
            failure = json.loads(output.getvalue())
            self.assertEqual(failure["code"], "inventory_invalid")
            self.assertEqual(failure["receipt_error_code"], "receipt_path_invalid")


if __name__ == "__main__":
    unittest.main()
