"""Tests for trusted Dependabot advisory intake."""

from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch
from urllib.error import HTTPError

from tools import archive_dependabot_advisory as advisory
from tools.archive_dependabot_advisory import (
    ADVISORY_MARKER,
    GitHubApi,
    archive_advisory,
)


class FakeApi:
    def __init__(
        self,
        pull: dict[str, Any],
        comments: list[dict[str, str]],
        *,
        label_exists: bool = True,
    ) -> None:
        self.pull = pull
        self.comments = comments
        self.label_exists = label_exists
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        allow_status: tuple[int, ...] = (),
    ) -> Any:
        del allow_status
        self.calls.append((method, path, payload))
        if method == "GET" and path.endswith("/pulls/42"):
            return self.pull
        if method == "GET" and "/pulls?" in path:
            return [self.pull]
        if method == "GET" and path.endswith("/labels/advisory-only"):
            return {"name": "advisory-only"} if self.label_exists else None
        if method == "GET" and "/issues/42/comments?" in path:
            return self.comments
        return None


class FakeResponse:
    def __init__(self, body: bytes) -> None:
        self.body = body

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


def _event(actor: str = "dependabot[bot]") -> dict[str, Any]:
    return {
        "repository": {
            "full_name": "blisspixel/quotabot",
            "default_branch": "main",
            "owner": {"login": "blisspixel"},
        },
        "workflow_run": {
            "event": "pull_request",
            "actor": {"login": actor},
            "head_branch": "dependabot/pub/app/example",
            "pull_requests": [{"number": 42}],
        },
    }


def _pull() -> dict[str, Any]:
    return {
        "number": 42,
        "state": "open",
        "user": {"login": "dependabot[bot]"},
        "head": {
            "ref": "dependabot/pub/app/example",
            "repo": {"full_name": "blisspixel/quotabot"},
        },
        "base": {
            "ref": "main",
            "repo": {"full_name": "blisspixel/quotabot"},
        },
    }


class ArchiveDependabotAdvisoryTest(unittest.TestCase):
    def test_github_api_sends_json_with_bounded_credentials(self) -> None:
        response = FakeResponse(b'{"ok": true}')
        with patch.object(advisory, "urlopen", return_value=response) as opener:
            result = GitHubApi("test-token", "https://api.github.test/").request(
                "POST", "/resource", {"value": 7}
            )

        self.assertEqual({"ok": True}, result)
        request = opener.call_args.args[0]
        self.assertEqual("https://api.github.test/resource", request.full_url)
        self.assertEqual("POST", request.get_method())
        self.assertEqual(b'{"value": 7}', request.data)
        self.assertEqual("Bearer test-token", request.get_header("Authorization"))
        self.assertEqual(30, opener.call_args.kwargs["timeout"])

    def test_github_api_handles_empty_and_allowed_missing_responses(self) -> None:
        api = GitHubApi("test-token", "https://api.github.test")
        with patch.object(advisory, "urlopen", return_value=FakeResponse(b"")):
            self.assertIsNone(api.request("DELETE", "/resource"))

        missing = HTTPError(
            "https://api.github.test/resource",
            404,
            "missing",
            {},
            io.BytesIO(b'{"message": "Not Found"}'),
        )
        with patch.object(advisory, "urlopen", side_effect=missing):
            self.assertIsNone(api.request("DELETE", "/resource", allow_status=(404,)))
        self.assertTrue(missing.closed)

    def test_github_api_surfaces_unexpected_error_without_token(self) -> None:
        api = GitHubApi("secret-value", "https://api.github.test")
        forbidden = HTTPError(
            "https://api.github.test/resource",
            403,
            "forbidden",
            {},
            io.BytesIO(b'{"message": "denied"}'),
        )
        with (
            patch.object(advisory, "urlopen", side_effect=forbidden),
            self.assertRaisesRegex(RuntimeError, "failed with 403") as raised,
        ):
            api.request("POST", "/resource", {"value": 7})

        self.assertTrue(forbidden.closed)
        self.assertNotIn("secret-value", str(raised.exception))

    def test_archives_valid_advisory_and_deletes_ref(self) -> None:
        api = FakeApi(_pull(), [])

        self.assertTrue(archive_advisory(_event(), api))

        self.assertIn(
            (
                "PATCH",
                "/repos/blisspixel/quotabot/pulls/42",
                {"state": "closed"},
            ),
            api.calls,
        )
        self.assertIn(
            (
                "DELETE",
                (
                    "/repos/blisspixel/quotabot/git/refs/heads/"
                    "dependabot/pub/app/example"
                ),
                None,
            ),
            api.calls,
        )
        comments = [
            payload
            for method, path, payload in api.calls
            if method == "POST" and path.endswith("/comments")
        ]
        self.assertEqual(1, len(comments))
        self.assertIn(ADVISORY_MARKER, comments[0]["body"])
        delete_index = next(
            index
            for index, (method, _, _) in enumerate(api.calls)
            if method == "DELETE"
        )
        comment_index = next(
            index
            for index, (method, path, _) in enumerate(api.calls)
            if method == "POST" and path.endswith("/comments")
        )
        self.assertLess(delete_index, comment_index)

    def test_does_not_duplicate_archive_comment(self) -> None:
        api = FakeApi(_pull(), [{"body": ADVISORY_MARKER}])

        self.assertTrue(archive_advisory(_event(), api))

        self.assertFalse(
            any(
                method == "POST" and path.endswith("/comments")
                for method, path, _ in api.calls
            )
        )

    def test_finds_pull_request_when_workflow_payload_omits_reference(self) -> None:
        event = _event()
        event["workflow_run"]["pull_requests"] = []
        api = FakeApi(_pull(), [])

        self.assertTrue(archive_advisory(event, api))
        self.assertTrue(
            any(method == "GET" and "/pulls?" in path for method, path, _ in api.calls)
        )

    def test_recreates_missing_advisory_label(self) -> None:
        api = FakeApi(_pull(), [], label_exists=False)

        self.assertTrue(archive_advisory(_event(), api))

        self.assertTrue(
            any(
                method == "POST"
                and path == "/repos/blisspixel/quotabot/labels"
                and payload is not None
                and payload["name"] == "advisory-only"
                for method, path, payload in api.calls
            )
        )

    def test_returns_cleanly_when_fallback_finds_no_matching_bot_pr(self) -> None:
        event = _event()
        event["workflow_run"]["pull_requests"] = [{"number": "not-an-integer"}]
        pull = _pull()
        pull["user"]["login"] = "someone-else"
        api = FakeApi(pull, [])

        self.assertFalse(archive_advisory(event, api))

    def test_closed_advisory_is_not_closed_again(self) -> None:
        pull = _pull()
        pull["state"] = "closed"
        api = FakeApi(pull, [])

        self.assertTrue(archive_advisory(_event(), api))
        self.assertFalse(any(method == "PATCH" for method, _, _ in api.calls))

    def test_ignores_non_dependabot_run_without_api_calls(self) -> None:
        api = FakeApi(_pull(), [])

        self.assertFalse(archive_advisory(_event(actor="blisspixel"), api))
        self.assertEqual([], api.calls)

    def test_rejects_untrusted_head_repository(self) -> None:
        pull = _pull()
        pull["head"]["repo"]["full_name"] = "attacker/quotabot"
        api = FakeApi(pull, [])

        with self.assertRaisesRegex(RuntimeError, "failed validation"):
            archive_advisory(_event(), api)

        self.assertEqual(1, len(api.calls))

    def test_main_requires_event_path_and_token(self) -> None:
        stderr = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), patch("sys.stderr", stderr):
            self.assertEqual(2, advisory.main())
        self.assertIn("GITHUB_EVENT_PATH and GH_TOKEN are required", stderr.getvalue())

    def test_main_reads_event_and_archives_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps(_event()), encoding="utf-8")
            environment = {
                "GITHUB_EVENT_PATH": str(event_path),
                "GH_TOKEN": "test-token",
                "GITHUB_API_URL": "https://api.github.test",
            }
            stdout = io.StringIO()
            with (
                patch.dict(os.environ, environment, clear=True),
                patch.object(advisory, "GitHubApi") as api_class,
                patch.object(
                    advisory, "archive_advisory", return_value=True
                ) as archive,
                patch("sys.stdout", stdout),
            ):
                self.assertEqual(0, advisory.main())

        api_class.assert_called_once_with("test-token", "https://api.github.test")
        archive.assert_called_once()
        self.assertIn("Dependency advisory archived", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
