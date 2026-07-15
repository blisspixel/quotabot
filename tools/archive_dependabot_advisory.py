"""Archive a Dependabot pull request as metadata, then remove its branch."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Protocol
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


DEPENDABOT_LOGIN = "dependabot[bot]"
ADVISORY_LABEL = "advisory-only"
ADVISORY_MARKER = "<!-- quotabot-dependency-advisory -->"
ADVISORY_COMMENT = f"""{ADVISORY_MARKER}
This pull request is retained as a dependency update warning only.

Do not merge or reuse this branch or commit. If the update is selected, recreate
it from current `main` on a first-party branch, review upstream and transitive
changes, and run the complete project gates. This bot branch is now removed.
"""


class Api(Protocol):
    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        allow_status: tuple[int, ...] = (),
    ) -> Any:
        raise NotImplementedError


class GitHubApi:
    def __init__(self, token: str, base_url: str) -> None:
        self._token = token
        self._base_url = base_url.rstrip("/")

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        allow_status: tuple[int, ...] = (),
    ) -> Any:
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
        request = Request(
            f"{self._base_url}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2026-03-10",
                "User-Agent": "quotabot-dependency-advisory-intake",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                body = response.read()
        except HTTPError as error:
            try:
                if error.code in allow_status:
                    return None
                detail = error.read().decode("utf-8", errors="replace")[:1000]
            finally:
                error.close()
            raise RuntimeError(
                f"GitHub API {method} {path} failed with {error.code}: {detail}"
            ) from error
        return json.loads(body) if body else None


def _eligible(event: dict[str, Any]) -> bool:
    run = event.get("workflow_run", {})
    return (
        run.get("event") == "pull_request"
        and run.get("actor", {}).get("login") == DEPENDABOT_LOGIN
        and str(run.get("head_branch", "")).startswith("dependabot/")
    )


def _load_pull_request(event: dict[str, Any], api: Api) -> dict[str, Any] | None:
    repository = event["repository"]
    run = event["workflow_run"]
    repo_path = f"/repos/{repository['full_name']}"

    for reference in run.get("pull_requests", []):
        number = reference.get("number")
        if isinstance(number, int):
            return api.request("GET", f"{repo_path}/pulls/{number}")

    owner = repository["owner"]["login"]
    query = urlencode(
        {
            "state": "all",
            "base": repository["default_branch"],
            "head": f"{owner}:{run['head_branch']}",
        }
    )
    candidates = api.request("GET", f"{repo_path}/pulls?{query}")
    for candidate in candidates:
        if (
            candidate.get("user", {}).get("login") == DEPENDABOT_LOGIN
            and candidate.get("head", {}).get("ref") == run["head_branch"]
        ):
            return candidate
    return None


def _validate_pull_request(event: dict[str, Any], pull: dict[str, Any]) -> None:
    repository = event["repository"]
    run = event["workflow_run"]
    expected = repository["full_name"]
    valid = (
        pull.get("user", {}).get("login") == DEPENDABOT_LOGIN
        and pull.get("head", {}).get("ref") == run["head_branch"]
        and pull.get("head", {}).get("repo", {}).get("full_name") == expected
        and pull.get("base", {}).get("ref") == repository["default_branch"]
        and pull.get("base", {}).get("repo", {}).get("full_name") == expected
    )
    if not valid:
        raise RuntimeError("Refusing to modify a pull request that failed validation")


def archive_advisory(event: dict[str, Any], api: Api) -> bool:
    """Archive one eligible advisory and return whether a PR was handled."""

    if not _eligible(event):
        return False

    pull = _load_pull_request(event, api)
    if pull is None:
        return False
    _validate_pull_request(event, pull)

    repository = event["repository"]
    repo_path = f"/repos/{repository['full_name']}"
    number = pull["number"]
    label_path = f"{repo_path}/labels/{quote(ADVISORY_LABEL, safe='')}"
    label = api.request("GET", label_path, allow_status=(404,))
    if label is None:
        api.request(
            "POST",
            f"{repo_path}/labels",
            {
                "name": ADVISORY_LABEL,
                "color": "d4c5f9",
                "description": (
                    "Warning only; recreate selected updates on a first-party branch"
                ),
            },
        )

    api.request(
        "POST",
        f"{repo_path}/issues/{number}/labels",
        {"labels": ["dependencies", ADVISORY_LABEL]},
    )
    comments = api.request("GET", f"{repo_path}/issues/{number}/comments?per_page=100")
    if pull.get("state") == "open":
        api.request(
            "PATCH",
            f"{repo_path}/pulls/{number}",
            {"state": "closed"},
        )

    encoded_ref = quote(f"heads/{pull['head']['ref']}", safe="/")
    api.request(
        "DELETE",
        f"{repo_path}/git/refs/{encoded_ref}",
        allow_status=(404,),
    )
    if not any(ADVISORY_MARKER in comment.get("body", "") for comment in comments):
        api.request(
            "POST",
            f"{repo_path}/issues/{number}/comments",
            {"body": ADVISORY_COMMENT},
        )
    return True


def main() -> int:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    token = os.environ.get("GH_TOKEN")
    if not event_path or not token:
        print("GITHUB_EVENT_PATH and GH_TOKEN are required", file=sys.stderr)
        return 2

    event = json.loads(Path(event_path).read_text(encoding="utf-8"))
    api = GitHubApi(token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    handled = archive_advisory(event, api)
    print("Dependency advisory archived" if handled else "No advisory to archive")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
