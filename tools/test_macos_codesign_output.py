"""Tests for strict Apple codesign output parsing."""

from __future__ import annotations

import plistlib
import unittest

from tools.macos_codesign_output import (
    MacOSCodeSignOutputError,
    code_directory_details,
    embedded_entitlements,
)


IDENTITY = "Developer ID Application: Example Publisher (ABCDEFGHIJ)"
TEAM_ID = "ABCDEFGHIJ"
CDHASH = "a" * 40


def _details() -> str:
    return "\n".join(
        (
            "CodeDirectory v=20500 flags=0x10000(runtime)",
            f"Authority={IDENTITY}",
            "Timestamp=Aug 30, 2026 at 12:00:00 PM",
            f"TeamIdentifier={TEAM_ID}",
            "Identifier=io.quotabot.cli",
            f"CDHash={CDHASH}",
        )
    )


class MacOSCodeSignOutputTests(unittest.TestCase):
    def test_complete_developer_id_details_and_entitlements_parse(self) -> None:
        self.assertEqual(
            code_directory_details(
                _details(),
                identity=IDENTITY,
                team_id=TEAM_ID,
                expected_identifier="io.quotabot.cli",
            ),
            CDHASH,
        )
        value = {"com.example.read-only": True}
        self.assertEqual(
            embedded_entitlements(plistlib.dumps(value).decode("utf-8")), value
        )
        self.assertEqual(embedded_entitlements("Executable=/tmp/example"), {})

    def test_identity_team_identifier_timestamp_and_runtime_are_required(self) -> None:
        for missing in (
            f"Authority={IDENTITY}",
            f"TeamIdentifier={TEAM_ID}",
            "Identifier=io.quotabot.cli",
            "Timestamp=Aug 30, 2026 at 12:00:00 PM",
            "CodeDirectory v=20500 flags=0x10000(runtime)",
        ):
            with self.subTest(missing=missing):
                with self.assertRaises(MacOSCodeSignOutputError):
                    code_directory_details(
                        _details().replace(missing, ""),
                        identity=IDENTITY,
                        team_id=TEAM_ID,
                        expected_identifier="io.quotabot.cli",
                    )

    def test_ad_hoc_mode_skips_identity_and_timestamp_only_when_requested(self) -> None:
        ad_hoc = "\n".join(
            (
                "CodeDirectory v=20500 flags=0x10002(adhoc,runtime)",
                "Identifier=io.quotabot.cli",
                f"CDHash={CDHASH}",
            )
        )
        self.assertEqual(
            code_directory_details(
                ad_hoc,
                identity=None,
                team_id=None,
                expected_identifier="io.quotabot.cli",
                require_timestamp=False,
            ),
            CDHASH,
        )

    def test_malformed_entitlement_output_fails_closed(self) -> None:
        with self.assertRaises(MacOSCodeSignOutputError):
            embedded_entitlements("<?xml version='1.0'?><plist>")


if __name__ == "__main__":
    unittest.main()
