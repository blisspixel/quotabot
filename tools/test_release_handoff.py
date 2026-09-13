from __future__ import annotations

import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import publish_release as publisher
from tools import release_handoff as handoff


def metadata() -> dict:
    return {
        "schema": handoff.SCHEMA,
        "repository": "blisspixel/quotabot",
        "tag": "v0.11.6",
        "source_digest": "a" * 40,
        "run_id": 123,
        "run_attempt": 1,
        "title": "v0.11.6",
        "body": "Claude and Codex quota reads remain metadata only.",
        "previous_tag": None,
        "previous_digest": None,
        "initial_release": True,
    }


class HandoffTests(unittest.TestCase):
    def test_final_audit_binds_the_actual_rerun_attempt(self):
        environment = {
            "GITHUB_REPOSITORY": "blisspixel/quotabot",
            "GITHUB_REF_NAME": "v0.11.6",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "2",
        }
        with (
            patch.dict(os.environ, environment),
            patch.object(handoff, "require_current_source"),
            patch.object(handoff, "asset_manifest", return_value={}),
        ):
            self.assertEqual(
                handoff.bind_manifest(metadata(), Path("unused"))["run_attempt"], 2
            )
            os.environ["GITHUB_RUN_ID"] = "124"
            with self.assertRaises(ValueError):
                handoff.bind_manifest(metadata(), Path("unused"))

    def test_product_references_are_allowed_but_credit_and_mentions_are_rejected(self):
        handoff.validate_metadata(metadata())
        for credit in (
            "Made by Claude",
            "Assisted by Codex",
            "Co-Authored-By: somebody",
            "Claude-Session: value",
            "Thanks to Copilot",
            "Changes by @dependabot[bot]",
        ):
            with self.subTest(credit=credit), self.assertRaises(ValueError):
                handoff.validate_metadata({**metadata(), "body": credit})

    def test_invalid_source_run_tag_and_previous_identity_fail_closed(self):
        for change in (
            {"schema": "unknown"},
            {"repository": "../owner/repo"},
            {"tag": "main"},
            {"source_digest": "short"},
            {"run_id": True},
            {"run_attempt": 0},
            {"title": "other"},
            {"body": ""},
            {"initial_release": False},
            {"previous_digest": "b" * 40},
            {
                "previous_tag": "v0.11.6",
                "previous_digest": "b" * 40,
                "initial_release": False,
            },
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                handoff.validate_metadata({**metadata(), **change})

    def test_real_previous_release_requires_its_original_digest(self):
        record = {
            **metadata(),
            "previous_tag": "v0.11.5",
            "previous_digest": "b" * 40,
            "initial_release": False,
        }
        handoff.validate_metadata(record)
        with self.assertRaises(ValueError):
            handoff.validate_metadata({**record, "previous_digest": None})

    def test_remote_tag_peeling_is_bounded_and_rejects_noncommits(self):
        with patch.object(
            handoff,
            "api",
            side_effect=[
                {"object": {"type": "tag", "sha": "b" * 40}},
                {"object": {"type": "commit", "sha": "a" * 40}},
            ],
        ):
            self.assertEqual(handoff.tag_commit("owner/repo", "v1.0.0"), "a" * 40)
        with patch.object(
            handoff, "api", return_value={"object": {"type": "tag", "sha": "b" * 40}}
        ) as request:
            with self.assertRaises(ValueError):
                handoff.tag_commit("owner/repo", "v1.0.0")
            self.assertLessEqual(request.call_count, 9)
        with (
            patch.object(
                handoff,
                "api",
                return_value={"object": {"type": "tree", "sha": "b" * 40}},
            ),
            self.assertRaises(ValueError),
        ):
            handoff.tag_commit("owner/repo", "v1.0.0")

    def test_main_or_remote_tag_movement_is_rejected(self):
        with (
            patch.object(handoff, "api", return_value={"sha": "b" * 40}),
            self.assertRaises(ValueError),
        ):
            handoff.require_current_source(metadata())
        with (
            patch.object(handoff, "api", return_value={"sha": "a" * 40}),
            patch.object(handoff, "tag_commit", return_value="b" * 40),
            self.assertRaises(ValueError),
        ):
            handoff.require_current_source(metadata())

    def test_prepare_requires_explicit_initial_release_and_keeps_the_real_notes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "CHANGELOG.md").write_text(
                "## 0.11.6 - 2026-09-13\n\nQuota fixes.\n\n## 0.11.5 - earlier\nOld notes.\n"
            )
            environment = {
                "GITHUB_REF_NAME": "v0.11.6",
                "GITHUB_REPOSITORY": "blisspixel/quotabot",
                "GITHUB_SHA": "a" * 40,
                "GITHUB_RUN_ID": "123",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_OUTPUT": str(root / "outputs"),
                "WINDOWS_SIGNING_BACKEND": "unsigned",
                "MACOS_SIGNING_MODE": "unsigned",
            }
            with (
                patch.object(handoff, "ROOT", root),
                patch.object(handoff, "gh", return_value="[[]]"),
                patch.object(handoff, "require_current_source"),
                patch.dict(os.environ, environment, clear=True),
            ):
                with self.assertRaisesRegex(ValueError, "explicit initial"):
                    handoff.prepare(root / "metadata.json")
                os.environ["ALLOW_INITIAL_RELEASE"] = "true"
                record = handoff.prepare(root / "metadata.json")
                self.assertTrue(record["initial_release"])
                self.assertIn("Quota fixes.", record["body"])
                self.assertNotIn("Old notes", record["body"])
                self.assertIn("previous_tag=\n", (root / "outputs").read_text())

    def test_manifest_requires_exact_inventory_and_detects_replaced_bytes(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(handoff, "verify_cli_archive"),
            patch.object(handoff, "verify_desktop_archive"),
        ):
            root = Path(temporary)
            for name in handoff.ASSETS:
                (root / name).write_bytes(name.encode())
            original = handoff.asset_manifest(root)
            (root / handoff.ARCHIVES[0]).write_bytes(b"changed")
            self.assertNotEqual(handoff.asset_manifest(root), original)
            (root / "unexpected.txt").write_text("extra")
            with self.assertRaises(ValueError):
                handoff.asset_manifest(root)
            (root / "unexpected.txt").unlink()
            (root / handoff.ARCHIVES[0]).unlink()
            with self.assertRaises(ValueError):
                handoff.asset_manifest(root)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.record = metadata()
        self.contents = {name: name.encode() for name in handoff.ASSETS}
        import hashlib

        self.record["assets"] = {
            name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
            for name, data in self.contents.items()
        }
        self.release = None
        self.assets = []
        self.published = False
        self.run = {
            "id": 123,
            "run_attempt": 1,
            "head_sha": "a" * 40,
            "head_branch": "v0.11.6",
            "event": "push",
            "path": handoff.WORKFLOW,
            "status": "completed",
            "conclusion": "success",
        }

    def api(self, endpoint, *, payload=None):
        if endpoint == "user":
            return {"type": "User", "login": "blisspixel"}
        if endpoint.endswith("/immutable-releases"):
            return {"enabled": True}
        if "/actions/runs/" in endpoint:
            return self.run
        if endpoint.endswith("/assets?per_page=100"):
            return copy.deepcopy(self.assets)
        if "/releases/" in endpoint:
            if payload:
                self.published = True
                self.release.update(draft=False, immutable=True)
            return copy.deepcopy(self.release)
        raise AssertionError(endpoint)

    def gh(self, *arguments, payload=None):
        if arguments[:2] == ("run", "download"):
            directory = Path(arguments[-1])
            for name, data in self.contents.items():
                (directory / name).write_bytes(data)
            (directory / "release-handoff.json").write_text(json.dumps(self.record))
        elif arguments[:2] == ("release", "create"):
            self.release = {
                "id": 9,
                "tag_name": self.record["tag"],
                "name": self.record["title"],
                "body": self.record["body"],
                "draft": True,
                "prerelease": False,
                "author": {"login": "blisspixel"},
                "html_url": "https://github.com/blisspixel/quotabot/releases/tag/v0.11.6",
            }
        elif arguments[:2] == ("release", "upload"):
            name = Path(arguments[3]).name
            expected = self.record["assets"][name]
            self.assets.append(
                {
                    "id": len(self.assets) + 1,
                    "name": name,
                    "size": expected["size"],
                    "digest": "sha256:" + expected["sha256"],
                    "state": "uploaded",
                    "uploader": {"login": "blisspixel"},
                    "updated_at": "fixed",
                }
            )
        elif arguments[:1] == ("api",):
            return "[[]]"
        else:
            raise AssertionError(arguments)
        return ""

    def run_process(self, arguments, **kwargs):
        if arguments[:3] == ["git", "rev-parse", "HEAD"]:
            return subprocess.CompletedProcess(arguments, 0, "a" * 40 + "\n")
        if arguments[:2] == ["git", "diff"]:
            return subprocess.CompletedProcess(arguments, 0)
        if arguments[:2] == ["gh", "api"]:
            self.assertIn("--allow-escape-sequences", arguments)
            identity = int(arguments[-1].rsplit("/", 1)[1])
            name = next(
                asset["name"] for asset in self.assets if asset["id"] == identity
            )
            kwargs["stdout"].write(self.contents[name])
            return subprocess.CompletedProcess(arguments, 0)
        raise AssertionError(arguments)

    def publish(self, directory):
        with (
            patch.object(publisher, "api", side_effect=self.api),
            patch.object(publisher, "gh", side_effect=self.gh),
            patch.object(publisher, "require_current_source"),
            patch.object(publisher, "verify_provenance"),
            patch.object(publisher.subprocess, "run", side_effect=self.run_process),
            patch.object(handoff, "verify_cli_archive"),
            patch.object(handoff, "verify_desktop_archive"),
        ):
            return publisher.publish("blisspixel/quotabot", 123, directory)

    def test_complete_owner_handoff_redownloads_before_immutable_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertTrue(self.publish(Path(temporary)).endswith("/v0.11.6"))
        self.assertTrue(self.published)
        self.assertEqual(len(self.assets), 14)

    def test_wrong_workflow_attempt_never_creates_a_release(self):
        self.run["run_attempt"] = 2
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValueError):
            self.publish(Path(temporary))
        self.assertIsNone(self.release)

    def test_incomplete_failed_or_wrong_source_run_never_creates_a_release(self):
        for key, value in (
            ("status", "in_progress"),
            ("conclusion", "failure"),
            ("head_sha", "b" * 40),
            ("path", ".github/workflows/other.yml"),
            ("event", "workflow_dispatch"),
        ):
            with self.subTest(key=key):
                original = self.run[key]
                self.run[key] = value
                with (
                    tempfile.TemporaryDirectory() as temporary,
                    self.assertRaises(ValueError),
                ):
                    self.publish(Path(temporary))
                self.assertIsNone(self.release)
                self.run[key] = original

    def test_changed_handoff_bytes_never_create_a_release(self):
        self.contents[handoff.ARCHIVES[0]] = b"changed"
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValueError):
            self.publish(Path(temporary))
        self.assertIsNone(self.release)

    def test_bot_identity_or_disabled_immutability_is_rejected(self):
        for replies in (
            [{"type": "Bot", "login": "blisspixel"}],
            [{"type": "User", "login": "someone-else"}],
            [{"type": "User", "login": "blisspixel"}, {"enabled": False}],
        ):
            with (
                self.subTest(replies=replies),
                patch.object(publisher, "api", side_effect=replies),
                self.assertRaises(ValueError),
            ):
                publisher.require_owner("blisspixel/quotabot")

    def test_existing_published_or_other_authored_draft_is_rejected(self):
        self.gh("release", "create")
        for change in (
            {"draft": False},
            {"body": "changed"},
            {"author": {"login": "github-actions[bot]"}},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                publisher.require_draft(
                    {**self.release, **change}, self.record, "blisspixel"
                )

    def test_changed_asset_uploader_digest_or_inventory_is_rejected(self):
        name = handoff.ARCHIVES[0]
        self.gh("release", "upload", "v0.11.6", name)
        for change in (
            {"uploader": {"login": "github-actions[bot]"}},
            {"digest": "sha256:" + "f" * 64},
            {"name": "unexpected.zip"},
            {"state": "new"},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                publisher.require_assets(
                    [{**self.assets[0], **change}],
                    self.record,
                    "blisspixel",
                    complete=False,
                )
        with self.assertRaises(ValueError):
            publisher.require_assets(
                self.assets, self.record, "blisspixel", complete=True
            )

    def test_attestation_verification_pins_source_tag_workflow_and_hosted_runner(self):
        with patch.object(publisher, "gh") as command:
            publisher.verify_provenance(Path("archive.zip"), self.record)
        arguments = command.call_args.args
        self.assertIn("--deny-self-hosted-runners", arguments)
        for flag, expected in (
            ("--source-ref", "refs/tags/v0.11.6"),
            ("--source-digest", "a" * 40),
            ("--signer-workflow", "blisspixel/quotabot/.github/workflows/release.yml"),
        ):
            self.assertEqual(arguments[arguments.index(flag) + 1], expected)


if __name__ == "__main__":
    unittest.main()
