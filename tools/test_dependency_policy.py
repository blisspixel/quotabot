"""Guard the repository's advisory-only dependency update policy."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPENDABOT = ROOT / ".github" / "dependabot.yml"
INTAKE = ROOT / ".github" / "workflows" / "dependency-advisory-intake.yml"


def _update_blocks(text: str) -> dict[tuple[str, str], str]:
    blocks: dict[tuple[str, str], str] = {}
    pattern = re.compile(
        r'^  - package-ecosystem: "(?P<ecosystem>[^"]+)"\n'
        r"(?P<body>.*?)(?=^  - package-ecosystem:|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    for match in pattern.finditer(text):
        body = match.group("body")
        directory = re.search(r'^    directory: "([^"]+)"$', body, re.MULTILINE)
        if directory is None:
            raise AssertionError(f"{match.group('ecosystem')}: directory is missing")
        blocks[(match.group("ecosystem"), directory.group(1))] = body
    return blocks


def _job_blocks(text: str) -> dict[str, str]:
    _, jobs = text.split("\njobs:\n", maxsplit=1)
    pattern = re.compile(
        r"^  (?P<name>[a-zA-Z0-9_-]+):\n"
        r"(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    return {
        match.group("name"): match.group("body") for match in pattern.finditer(jobs)
    }


class DependencyPolicyTest(unittest.TestCase):
    def test_every_update_is_bounded_and_advisory_only(self) -> None:
        text = DEPENDABOT.read_text(encoding="utf-8")
        blocks = _update_blocks(text)
        expected = {
            ("github-actions", "/"),
            ("pub", "/collector"),
            ("pub", "/app"),
            ("npm", "/integrations/mcp_clients"),
            ("pip", "/integrations/litellm"),
        }

        self.assertEqual(expected, set(blocks))
        for identity, body in blocks.items():
            with self.subTest(update=identity):
                self.assertRegex(
                    body,
                    r"(?m)^    open-pull-requests-limit: 1$",
                )
                self.assertRegex(
                    body,
                    r'(?m)^    rebase-strategy: "disabled"$',
                )
                self.assertRegex(
                    body,
                    r'(?m)^      prefix: "advisory\(deps\)"$',
                )
                self.assertRegex(
                    body,
                    r'(?m)^      - "dependencies"$',
                )
                self.assertRegex(
                    body,
                    r'(?m)^      - "advisory-only"$',
                )

    def test_agent_rules_reject_dependabot_branches(self) -> None:
        for name in ("AGENTS.md", "CLAUDE.md"):
            with self.subTest(file=name):
                text = (ROOT / name).read_text(encoding="utf-8")
                self.assertRegex(
                    text,
                    r"Never merge, amend, or reuse a\s+Dependabot branch",
                )

    def test_intake_uses_trusted_second_stage(self) -> None:
        text = INTAKE.read_text(encoding="utf-8")
        self.assertIn("workflow_run:", text)
        self.assertIn("workflows: [CI]", text)
        self.assertIn("branches: ['dependabot/**']", text)
        self.assertIn("ref: main", text)
        self.assertIn("persist-credentials: false", text)
        self.assertNotIn("pull_request_target:", text)
        self.assertNotIn("workflow_run.head_sha", text)

    def test_dependabot_jobs_are_not_executed(self) -> None:
        workflows = (
            "ci.yml",
            "codeql.yml",
            "dependency-review.yml",
            "gitleaks.yml",
        )
        guard = "if: github.actor != 'dependabot[bot]'"
        for name in workflows:
            with self.subTest(workflow=name):
                text = (ROOT / ".github" / "workflows" / name).read_text(
                    encoding="utf-8"
                )
                blocks = _job_blocks(text)
                self.assertTrue(blocks)
                for job, body in blocks.items():
                    with self.subTest(workflow=name, job=job):
                        self.assertIn(guard, body)

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("tools.test_archive_dependabot_advisory", ci)

    def test_litellm_resolver_uses_the_ci_python_line(self) -> None:
        runtime = (ROOT / "integrations" / "litellm" / ".python-version").read_text(
            encoding="utf-8"
        )
        self.assertRegex(runtime, r"^3\.13\.\d+\n?$")

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("python-version: '3.13'", ci)

        requirements = (
            ROOT / "integrations" / "litellm" / "requirements.in"
        ).read_text(encoding="utf-8")
        self.assertIn("Python 3.10 through 3.13 only", requirements)


if __name__ == "__main__":
    unittest.main()
