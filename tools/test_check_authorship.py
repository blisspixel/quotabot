"""Exercise authorship policy against isolated Git object graphs."""

from __future__ import annotations

import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from tools.check_authorship import (
    AuthorshipError,
    check_repository,
    load_legacy_refs,
    main as check_main,
    message_violations,
    object_violations,
)


HUMAN = "Nick Seal <32712898+blisspixel@users.noreply.github.com>"
WEB_FLOW = "GitHub <noreply@github.com>"
BOT = "dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>"
STAMP = "1720000000 +0000"


def commit_text(
    tree: str,
    author: str = HUMAN,
    committer: str = HUMAN,
    message: str = "Fix quota metadata",
    parent: str | None = None,
) -> str:
    parent_line = f"parent {parent}\n" if parent else ""
    return f"tree {tree}\n{parent_line}author {author} {STAMP}\ncommitter {committer} {STAMP}\n\n{message}\n"


class AuthorshipTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="quotabot-authorship-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "--quiet", "--initial-branch=main")
        self.tree = self.git(
            "hash-object", "-t", "tree", "-w", "--stdin", data=""
        ).strip()

    def git(self, *arguments: str, data: str | None = None) -> str:
        environment = os.environ.copy()
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = os.devnull
        return subprocess.run(
            ["git", "-C", str(self.root), *arguments],
            input=data.encode("utf-8") if data is not None else None,
            capture_output=True,
            env=environment,
            timeout=10,
            check=True,
        ).stdout.decode("utf-8")

    def commit(self, ref: str = "refs/heads/main", **kwargs: str) -> str:
        raw = commit_text(self.tree, **kwargs)
        object_id = self.git(
            "hash-object", "-t", "commit", "-w", "--stdin", data=raw
        ).strip()
        self.git("update-ref", ref, object_id)
        return object_id

    def tag(
        self,
        commit: str,
        tagger: str = HUMAN,
        message: str = "Release 0.11.6",
        name: str = "v0.11.6",
    ) -> str:
        raw = f"object {commit}\ntype commit\ntag {name}\ntagger {tagger} {STAMP}\n\n{message}\n"
        object_id = self.git(
            "hash-object", "-t", "tag", "-w", "--stdin", data=raw
        ).strip()
        self.git("update-ref", "refs/tags/" + name, object_id)
        return object_id

    def historical_graph(self) -> tuple[str, dict[str, tuple[str, str]]]:
        self.commit(message="Current owner history")
        old = self.commit(ref="refs/tags/v0.5.2", author=BOT)
        tag = self.tag(old, name="v0.5.2")
        return old, {"refs/tags/v0.5.2": ("tag", tag)}

    def test_owner_root_and_web_flow_committer_are_accepted(self) -> None:
        root = self.commit(message="Initial source")
        self.commit(parent=root, committer=WEB_FLOW)
        self.tag(root)
        self.assertEqual((2, 1, []), check_repository(self.root))

    def test_bot_on_other_branch_is_rejected_even_with_clean_main(self) -> None:
        self.commit()
        bot = self.commit(ref="refs/heads/update", author=BOT)
        _, _, failures = check_repository(self.root)
        self.assertIn(f"commit {bot}: unapproved author identity", failures)

    def test_remote_tracking_history_is_checked(self) -> None:
        self.commit()
        self.commit(ref="refs/remotes/origin/update", committer=BOT)
        self.assertTrue(check_repository(self.root)[2])

    def test_tag_metadata_cannot_hide_in_another_ref_namespace(self) -> None:
        tag = self.tag(self.commit(), tagger=BOT)
        self.git("update-ref", "refs/archive/release", tag)
        self.git("update-ref", "-d", "refs/tags/v0.11.6")
        self.assertIn(
            f"tag object {tag}: unapproved tagger identity",
            check_repository(self.root)[2],
        )

    def test_bot_ancestor_is_not_hidden_by_human_tip(self) -> None:
        parent = self.commit(author=BOT)
        self.commit(parent=parent)
        self.assertTrue(check_repository(self.root)[2])

    def test_exact_historical_tag_can_preserve_disconnected_history(self) -> None:
        _, baseline = self.historical_graph()
        self.assertEqual((1, 1, []), check_repository(self.root, legacy_refs=baseline))

    def test_exact_historical_lightweight_tag_is_accepted(self) -> None:
        self.commit(message="Current owner history")
        old = self.commit(ref="refs/tags/v0.5.2", author=BOT)
        baseline = {"refs/tags/v0.5.2": ("commit", old)}
        self.assertEqual((1, 1, []), check_repository(self.root, legacy_refs=baseline))
        self.tag(old, name="v0.5.2")
        self.assertTrue(check_repository(self.root, legacy_refs=baseline)[2])

    def test_historical_pin_cannot_mask_bot_ancestor_on_main(self) -> None:
        old, baseline = self.historical_graph()
        self.commit(parent=old)
        self.assertIn(
            f"commit {old}: unapproved author identity",
            check_repository(self.root, legacy_refs=baseline)[2],
        )

    def test_historical_pin_cannot_mask_other_active_refs(self) -> None:
        old, baseline = self.historical_graph()
        for ref in (
            "refs/heads/restored",
            "refs/remotes/origin/restored",
            "refs/archive/restored",
        ):
            with self.subTest(ref=ref):
                self.commit(ref=ref, parent=old)
                self.assertIn(
                    f"commit {old}: unapproved author identity",
                    check_repository(self.root, legacy_refs=baseline)[2],
                )
                self.git("update-ref", "-d", ref)

    def test_historical_pin_cannot_mask_bot_ancestor_under_new_tag(self) -> None:
        old, baseline = self.historical_graph()
        self.tag(old)
        self.assertIn(
            f"commit {old}: unapproved author identity",
            check_repository(self.root, legacy_refs=baseline)[2],
        )

    def test_detached_head_is_checked_even_when_exact_legacy_tag_is_exempt(
        self,
    ) -> None:
        old, baseline = self.historical_graph()
        self.git("checkout", "--quiet", "--detach", old)
        self.assertIn(
            f"commit {old}: unapproved author identity",
            check_repository(self.root, legacy_refs=baseline)[2],
        )

    def test_changed_historical_tag_fails_even_with_owner_replacement(self) -> None:
        _, baseline = self.historical_graph()
        current = self.git("rev-parse", "HEAD").strip()
        self.tag(current, name="v0.5.2", message="Changed release metadata")
        self.assertEqual(
            ["tag refs/tags/v0.5.2: historical release ref differs from its pin"],
            check_repository(self.root, legacy_refs=baseline)[2],
        )

    def test_renamed_historical_object_fails_even_with_clean_owner_history(
        self,
    ) -> None:
        current = self.commit()
        old_tag = self.tag(current, name="v0.5.2")
        baseline = {"refs/tags/v0.5.2": ("tag", old_tag)}
        self.git("update-ref", "-d", "refs/tags/v0.5.2")
        self.git("update-ref", "refs/tags/renamed-release", old_tag)
        self.assertEqual(
            [
                "tag refs/tags/renamed-release: historical release object requires its pinned name"
            ],
            check_repository(self.root, legacy_refs=baseline)[2],
        )

    def test_target_checkout_cannot_supply_a_different_baseline(self) -> None:
        old, baseline = self.historical_graph()
        policy = self.root / "tools" / "legacy_release_refs.json"
        policy.parent.mkdir()
        policy.write_text(
            json.dumps(
                {
                    "schema": "quotabot.legacy-release-refs.v1",
                    "repository": "blisspixel/quotabot",
                    "refs": [
                        {"name": name, "object_type": kind, "object_id": oid}
                        for name, (kind, oid) in baseline.items()
                    ],
                }
            ),
            encoding="utf-8",
        )
        failures = check_repository(self.root)[2]
        self.assertIn(f"commit {old}: unapproved author identity", failures)
        self.assertIn(
            "tag refs/tags/v0.5.2: historical release ref differs from its pin",
            failures,
        )

    def test_canonical_baseline_excludes_unpublished_release(self) -> None:
        baseline = load_legacy_refs()
        self.assertEqual(57, len(baseline))
        self.assertEqual(8, sum(kind == "commit" for kind, _ in baseline.values()))
        self.assertNotIn("refs/tags/v0.11.6", baseline)
        self.assertEqual(
            ("tag", "0842f7fc19d71a1db191b1ab064b57dcf5d7062c"),
            baseline["refs/tags/v0.11.5"],
        )

    def test_cli_exit_status_changes_when_bot_history_is_reintroduced(self) -> None:
        self.commit()
        with redirect_stdout(io.StringIO()):
            self.assertEqual(0, check_main(["--repo", str(self.root)]))
        bot = self.commit(ref="refs/remotes/origin/restored", author=BOT)
        errors = io.StringIO()
        with redirect_stderr(errors):
            self.assertEqual(1, check_main(["--repo", str(self.root)]))
        self.assertIn(f"commit {bot}: unapproved author identity", errors.getvalue())

    def test_cli_missing_canonical_baseline_fails_closed(self) -> None:
        self.commit()
        with patch(
            "tools.check_authorship.LEGACY_REFS_PATH", self.root / "missing.json"
        ):
            with redirect_stderr(io.StringIO()):
                self.assertEqual(1, check_main(["--repo", str(self.root)]))

    def test_malformed_and_duplicate_baseline_pins_fail_closed(self) -> None:
        path = self.root / "invalid-baseline.json"
        pin = {"name": "refs/tags/v0.5.2", "object_type": "tag", "object_id": "a" * 40}
        for refs in (
            [pin, pin],
            [{**pin, "object_id": "not-an-object-id"}],
            [{**pin, "name": "refs/heads/main"}],
            [{**pin, "object_type": "blob"}],
        ):
            with self.subTest(refs=refs):
                path.write_text(
                    json.dumps(
                        {
                            "schema": "quotabot.legacy-release-refs.v1",
                            "repository": "blisspixel/quotabot",
                            "refs": refs,
                        }
                    ),
                    encoding="utf-8",
                )
                with patch("tools.check_authorship.LEGACY_REFS_PATH", path):
                    with self.assertRaisesRegex(
                        AuthorshipError, "historical release ref"
                    ):
                        load_legacy_refs()

    def test_bot_tagger_and_tag_attribution_are_rejected(self) -> None:
        self.tag(self.commit(), tagger=BOT, message="Release\n\nGenerated with Codex")
        failures = check_repository(self.root)[2]
        self.assertTrue(any("unapproved tagger" in failure for failure in failures))
        self.assertTrue(
            any("assistant credit marker" in failure for failure in failures)
        )

    def test_lightweight_tag_cannot_claim_human_tagger(self) -> None:
        self.git("update-ref", "refs/tags/v0.11.6", self.commit())
        self.assertTrue(check_repository(self.root)[2])

    def test_nested_tag_cannot_hide_another_tagger(self) -> None:
        inner = self.tag(self.commit(), tagger=BOT)
        outer = (
            f"object {inner}\ntype tag\ntag outer\ntagger {HUMAN} {STAMP}\n\nRelease\n"
        )
        outer_id = self.git(
            "hash-object", "-t", "tag", "-w", "--stdin", data=outer
        ).strip()
        self.git("update-ref", "refs/tags/v0.11.6", outer_id)
        self.assertEqual(
            [f"tag object {outer_id}: annotated tag must point directly to a commit"],
            check_repository(self.root)[2],
        )

    def test_shallow_history_is_rejected(self) -> None:
        commit = self.commit()
        (self.root / ".git" / "shallow").write_text(commit + "\n", encoding="ascii")
        with self.assertRaisesRegex(AuthorshipError, "complete"):
            check_repository(self.root)

    def test_git_replace_cannot_hide_original_author(self) -> None:
        original = self.commit(author=BOT)
        replacement = self.git(
            "hash-object", "-t", "commit", "-w", "--stdin", data=commit_text(self.tree)
        ).strip()
        self.git("replace", original, replacement)
        self.assertTrue(check_repository(self.root)[2])

    def test_exact_identities_fail_closed(self) -> None:
        for identity in (
            BOT,
            "Codex <codex@openai.com>",
            "Nick Seal <other@example.test>",
            WEB_FLOW,
        ):
            with self.subTest(identity=identity):
                self.assertIn(
                    "unapproved author identity",
                    object_violations(
                        commit_text(self.tree, author=identity, committer=WEB_FLOW),
                        "commit",
                    ),
                )

    def test_duplicate_identity_headers_are_rejected(self) -> None:
        raw = commit_text(self.tree).replace(
            "\ncommitter ", f"\nauthor {BOT} {STAMP}\ncommitter "
        )
        with self.assertRaisesRegex(AuthorshipError, "exactly one author"):
            object_violations(raw, "commit")

    def test_known_attribution_trailers_and_credit_markers_are_rejected(self) -> None:
        for text in (
            "Co-Authored-By: Nick Seal <human@example.test>",
            "co-authored-by: Codex <assistant@example.test>",
            "Claude-Session: https://example.test/session",
            "Signed-off-by: Nick Seal <human@example.test>",
            "Generated with Claude Code",
            "Generated with [Codex](https://example.test)",
            "Assisted by GitHub Copilot",
            "by an AI assistant",
        ):
            with self.subTest(text=text):
                self.assertTrue(message_violations("Fix metadata\n\n" + text))

    def test_technical_provider_names_are_not_attribution(self) -> None:
        for text in (
            "Fix Claude quota parsing and Codex account metadata",
            "Update CLAUDE.md and integrations/agent_plugin",
            "Read metadata returned by Claude and GitHub.",
            "Keep Gemini, Grok, Kiro, Cursor and Copilot catalog evidence separate.",
            "Reject Co-Authored-By trailers in commit metadata.",
        ):
            with self.subTest(text=text):
                self.assertEqual([], message_violations(text))


if __name__ == "__main__":
    unittest.main()
