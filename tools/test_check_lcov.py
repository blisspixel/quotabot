"""Regression tests for the repository LCOV coverage gate."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class CheckLcovTest(unittest.TestCase):
    def run_checker(
        self,
        report: str,
        minimum: int,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lcov.info"
            path.write_text(report, encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("check_lcov.py")),
                    str(path),
                    str(minimum),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_rejects_report_without_executable_lines(self) -> None:
        result = self.run_checker("TN:\nend_of_record\n", 80)

        self.assertEqual(result.returncode, 1)
        self.assertIn("no executable lines", result.stderr)

    def test_enforces_minimum_against_executable_lines(self) -> None:
        passing = self.run_checker("DA:1,1\nDA:2,1\nDA:3,0\n", 60)
        failing = self.run_checker("DA:1,1\nDA:2,0\nDA:3,0\n", 60)

        self.assertEqual(passing.returncode, 0)
        self.assertIn("66.67%", passing.stdout)
        self.assertEqual(failing.returncode, 1)
        self.assertIn("coverage below required", failing.stderr)


if __name__ == "__main__":
    unittest.main()
