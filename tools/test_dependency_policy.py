"""Guard the repository's advisory-only dependency update policy."""

from __future__ import annotations

import re
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPENDABOT = ROOT / ".github" / "dependabot.yml"
INTAKE = ROOT / ".github" / "workflows" / "dependency-advisory-intake.yml"
WORKFLOWS = ROOT / ".github" / "workflows"


_PUB_GET = re.compile(r"(?<![\w-])(?:dart|flutter)\s+pub\s+get\b")
_LOCKFILE_FLAG = re.compile(r"(?<!\S)--enforce-lockfile(?:\s|$)")
_SHELL_COMMAND_END = re.compile(r"\r?\n|&&|\|\||[;|]")
_SHELL_CONTINUATION = re.compile(r"(?:\\|`)\s*\r?\n\s*")


def _workflow_run_scripts(text: str) -> list[str]:
    """Extract inline and block-style workflow run scripts without PyYAML."""
    lines = text.splitlines()
    scripts: list[str] = []
    index = 0
    while index < len(lines):
        match = re.match(r"^(?P<indent>\s*)run:\s*(?P<value>.*)$", lines[index])
        if match is None:
            index += 1
            continue

        value = match.group("value").strip()
        if value not in {"|", "|-", "|+", ">", ">-", ">+"}:
            scripts.append(value)
            index += 1
            continue

        base_indent = len(match.group("indent"))
        block: list[str] = []
        index += 1
        while index < len(lines):
            line = lines[index]
            if line.strip() and len(line) - len(line.lstrip()) <= base_indent:
                break
            block.append(line)
            index += 1

        nonempty_indents = [
            len(line) - len(line.lstrip()) for line in block if line.strip()
        ]
        content_indent = min(nonempty_indents, default=base_indent + 1)
        content = [line[content_indent:] if line.strip() else "" for line in block]
        if value.startswith(">"):
            scripts.append(" ".join(part.strip() for part in content))
        else:
            scripts.append("\n".join(content))

    return scripts


def _assert_workflow_pub_gets_are_locked(text: str, source: str) -> None:
    violations: list[str] = []
    for script in _workflow_run_scripts(text):
        normalized = _SHELL_CONTINUATION.sub(" ", script)
        for match in _PUB_GET.finditer(normalized):
            invocation = _SHELL_COMMAND_END.split(normalized[match.start() :], 1)[0]
            invocation = re.sub(r"\s+#.*$", "", invocation).strip()
            if _LOCKFILE_FLAG.search(invocation) is None:
                violations.append(invocation)

    if violations:
        rendered = ", ".join(repr(violation) for violation in violations)
        raise AssertionError(
            f"{source} resolves pub dependencies without --enforce-lockfile: {rendered}"
        )


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


def _checkout_blocks(text: str) -> list[str]:
    lines = text.splitlines()
    blocks: list[str] = []
    for index, line in enumerate(lines):
        if "uses: actions/checkout@" not in line:
            continue
        uses_indent = len(line) - len(line.lstrip())
        step_indent = uses_indent if line.lstrip().startswith("- ") else uses_indent - 2
        block = [line]
        for following in lines[index + 1 :]:
            following_indent = len(following) - len(following.lstrip())
            if following.strip() and following_indent <= step_indent:
                break
            block.append(following)
        blocks.append("\n".join(block))
    return blocks


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
                    r'(?m)^    target-branch: "main"$',
                )
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

    def test_litellm_resolver_uses_the_supported_python_line(self) -> None:
        metadata = tomllib.loads(
            (ROOT / "integrations" / "litellm" / "pyproject.toml").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(">=3.10,<3.14", metadata["project"]["requires-python"])

        runtime = (ROOT / "integrations" / "litellm" / ".python-version").read_text(
            encoding="utf-8"
        )
        self.assertRegex(runtime, r"^3\.13\.\d+\n?$")

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("python-version: '3.13'", ci)

        requirements = (
            ROOT / "integrations" / "litellm" / "requirements.in"
        ).read_text(encoding="utf-8")
        self.assertIn("Python 3.10 through 3.13", requirements)

    def test_ci_and_release_enforce_committed_pub_lockfiles(self) -> None:
        expected = {
            "ci.yml": (
                "dart pub get --enforce-lockfile",
                "flutter pub get --enforce-lockfile",
                "flutter analyze --no-pub",
                "flutter test --no-pub --coverage",
            ),
            "currency.yml": ("dart pub get --enforce-lockfile",),
            "release.yml": (
                "dart pub get --enforce-lockfile",
                "flutter pub get --enforce-lockfile",
            ),
        }
        for name, commands in expected.items():
            with self.subTest(workflow=name):
                text = (ROOT / ".github" / "workflows" / name).read_text(
                    encoding="utf-8"
                )
                for command in commands:
                    self.assertIn(command, text)
                _assert_workflow_pub_gets_are_locked(text, name)

        workflow_paths = sorted(WORKFLOWS.glob("*.yml")) + sorted(
            WORKFLOWS.glob("*.yaml")
        )
        for path in workflow_paths:
            with self.subTest(workflow=path.name, policy="all-workflows"):
                _assert_workflow_pub_gets_are_locked(
                    path.read_text(encoding="utf-8"),
                    path.name,
                )

    def test_every_checkout_discards_its_git_credential(self) -> None:
        workflow_paths = sorted(WORKFLOWS.glob("*.yml")) + sorted(
            WORKFLOWS.glob("*.yaml")
        )
        checkout_count = 0
        for path in workflow_paths:
            blocks = _checkout_blocks(path.read_text(encoding="utf-8"))
            checkout_count += len(blocks)
            for block in blocks:
                with self.subTest(workflow=path.name, checkout=block.splitlines()[0]):
                    self.assertIn("persist-credentials: false", block)
        self.assertGreater(checkout_count, 0)

    def test_pub_lockfile_scanner_covers_every_workflow_run_style(self) -> None:
        guarded = (
            "jobs:\n"
            "  inline:\n"
            "    run: dart pub get --enforce-lockfile\n"
            "  literal:\n"
            "    run: |\n"
            "      flutter pub get \\\n"
            "        --enforce-lockfile\n"
            "  powershell:\n"
            "    run: |\n"
            "      dart pub get `\n"
            "        --enforce-lockfile\n"
            "  folded:\n"
            "    run: >-\n"
            "      flutter pub get\n"
            "      --enforce-lockfile\n"
        )
        _assert_workflow_pub_gets_are_locked(guarded, "guarded.yml")

        unguarded = {
            "inline": "jobs:\n  test:\n    run: dart pub get\n",
            "literal": "jobs:\n  test:\n    run: |\n      flutter pub get\n",
            "continued": (
                "jobs:\n  test:\n    run: |\n      dart pub get \\\n        --offline\n"
            ),
            "folded": (
                "jobs:\n  test:\n    run: >\n      flutter pub get\n      --offline\n"
            ),
        }
        for style, workflow in unguarded.items():
            with self.subTest(style=style):
                with self.assertRaisesRegex(
                    AssertionError,
                    "without --enforce-lockfile",
                ):
                    _assert_workflow_pub_gets_are_locked(workflow, f"{style}.yml")

    def test_source_setup_and_packaging_enforce_committed_lockfiles(self) -> None:
        expected = {
            "setup.ps1": (
                "dart pub get --enforce-lockfile",
                "flutter pub get --enforce-lockfile",
                "flutter build windows --release --no-pub",
            ),
            "setup.sh": (
                "dart pub get --enforce-lockfile",
                "flutter pub get --enforce-lockfile",
                "flutter build macos --release --no-pub",
                "flutter build linux --release --no-pub",
            ),
            "package-cli.ps1": ("dart pub get --enforce-lockfile",),
            "package-cli.sh": ("dart pub get --enforce-lockfile",),
            "package-windows.ps1": (
                "flutter pub get --enforce-lockfile",
                "flutter build windows --release --no-pub",
            ),
            "package-macos.sh": (
                "flutter pub get --enforce-lockfile",
                "flutter build macos --release --no-pub",
            ),
            "package-linux.sh": (
                "flutter pub get --enforce-lockfile",
                "flutter build linux --release --no-pub",
            ),
        }
        for name, commands in expected.items():
            with self.subTest(script=name):
                text = (ROOT / "tools" / name).read_text(encoding="utf-8")
                for command in commands:
                    self.assertIn(command, text)

    def test_ci_and_release_toolchains_are_reproducible(self) -> None:
        flutter_version = "3.44.6"
        flutter_commit = "ee80f08bbf97172ec030b8751ceab557177a34a6"
        flutter_workflows = (
            "ci.yml",
            "currency.yml",
            "install-smoke.yml",
            "release.yml",
        )
        for name in flutter_workflows:
            with self.subTest(workflow=name):
                text = (ROOT / ".github" / "workflows" / name).read_text(
                    encoding="utf-8"
                )
                self.assertIn("./tools/setup-flutter-ci.ps1", text)
                self.assertIn(f"-FlutterVersion '{flutter_version}'", text)
                self.assertIn(f"-ExpectedCommit '{flutter_commit}'", text)
                self.assertNotIn("subosito/flutter-action@", text)
                self.assertNotIn("channel: stable", text)

        flutter_setup = (ROOT / "tools" / "setup-flutter-ci.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn(f"[string]$FlutterVersion = '{flutter_version}'", flutter_setup)
        self.assertIn(f"[string]$ExpectedCommit = '{flutter_commit}'", flutter_setup)
        self.assertIn("https://github.com/flutter/flutter.git", flutter_setup)
        self.assertIn("rev-parse HEAD", flutter_setup)
        self.assertIn("if ($actualCommit -ne $ExpectedCommit)", flutter_setup)

        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("sdk: '3.12.2'", release)
        self.assertEqual(6, release.count("uses: actions/setup-python@"))
        self.assertEqual(6, release.count("python-version: '3.13'"))

        install_smoke = (
            ROOT / ".github" / "workflows" / "install-smoke.yml"
        ).read_text(encoding="utf-8")
        self.assertEqual(2, install_smoke.count("uses: actions/setup-python@"))
        self.assertEqual(2, install_smoke.count("python-version: '3.13'"))

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("dart run coverage:format_coverage", ci)
        self.assertNotIn("dart pub global activate coverage", ci)
        self.assertNotIn("dart pub global run coverage:format_coverage", ci)

    def test_ci_enforces_python_and_workflow_lint(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        static_job = _job_blocks(ci)["static-quality"]
        self.assertIn(
            "astral-sh/ruff-action@278981a28ce3188b1e39527901f38254bf3aac89",
            static_job,
        )
        self.assertIn("version: '0.15.16'", static_job)
        self.assertIn("args: 'check --output-format=github'", static_job)
        self.assertIn("args: 'format --check'", static_job)
        self.assertIn("actionlint_1.7.7_linux_amd64.tar.gz", static_job)
        self.assertIn(
            "023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757",
            static_job,
        )
        self.assertIn("sha256sum --check --strict", static_job)


if __name__ == "__main__":
    unittest.main()
