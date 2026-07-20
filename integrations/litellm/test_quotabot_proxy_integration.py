"""Real LiteLLM proxy integration coverage for the quotabot router.

The test runs only when explicitly enabled because it starts the LiteLLM proxy
and requires the optional proxy dependencies. It stays fully local: the quota
server and the OpenAI-compatible model backend are loopback test doubles.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


INTEGRATION_DIR = Path(__file__).resolve().parent
RUN_PROXY_TEST = os.environ.get("QUOTABOT_RUN_LITELLM_PROXY_TEST") == "1"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _json_response(
    handler: BaseHTTPRequestHandler,
    status: int,
    payload: dict[str, Any],
) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class _SilentHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        return None


class _FakeQuotabotHandler(_SilentHandler):
    requests_seen = 0
    reservations_seen = 0
    releases_seen = 0
    mutation_token = "quotabot-proxy-mutation-token-012345"

    def do_GET(self) -> None:
        if self.path != "/suggest":
            _json_response(self, 404, {"error": "not found"})
            return
        type(self).requests_seen += 1
        _json_response(
            self,
            200,
            {
                "schema": "quotabot.suggest.v1",
                "recommended": {
                    "provider": "claude",
                    "headroom_percent": 72,
                    "available": True,
                },
                "ranked": [
                    {
                        "provider": "claude",
                        "account": "claude-account",
                        "headroom_percent": 72,
                        "effective_headroom_percent": 72,
                        "available": True,
                    },
                    {
                        "provider": "codex",
                        "account": "codex-account",
                        "headroom_percent": 8,
                        "effective_headroom_percent": 8,
                        "available": True,
                    },
                ],
                "fallback": {
                    "provider": "ollama",
                    "headroom_percent": 100,
                    "is_local": True,
                },
                "reason": "proxy integration test",
                "as_of": 1782000000,
                "receipt": {
                    "schema": "quotabot.receipt.v1",
                    "decision_id": "qb-1782000000-0123456789abcdef",
                },
            },
        )

    def do_POST(self) -> None:
        if self.headers.get("Authorization") != f"Bearer {type(self).mutation_token}":
            _json_response(self, 401, {"error": "unauthorized"})
            return
        length = int(self.headers.get("Content-Length") or "0")
        payload = json.loads(self.rfile.read(length).decode("utf-8"))
        if self.path == "/leases/reserve":
            type(self).reservations_seen += 1
            targets = payload.get("targets")
            if not isinstance(targets, list) or not any(
                target.get("provider") == "claude"
                for target in targets
                if isinstance(target, dict)
            ):
                _json_response(self, 400, {"error": "missing target"})
                return
            _json_response(
                self,
                200,
                {
                    "schema": "quotabot.reserve.v1",
                    "reserved": True,
                    "reused": False,
                    "lease": {
                        "id": "proxy-test-lease-0001",
                        "provider": "claude",
                        "account": "claude-account",
                        "created_at": 1782000000,
                        "expires_at": 1782000120,
                        "weight_percent": payload["weight_percent"],
                        "client": payload["client"],
                        "idempotency_key": payload["idempotency_key"],
                    },
                    "selected": {
                        "provider": "claude",
                        "account": "claude-account",
                        "available": True,
                        "effective_headroom_percent": 72,
                    },
                    "decision_id": "qb-1782000000-0123456789abcdef",
                },
            )
            return
        if self.path == "/leases/release":
            if payload.get("lease_id") != "proxy-test-lease-0001":
                _json_response(self, 400, {"error": "invalid lease"})
                return
            type(self).releases_seen += 1
            _json_response(
                self,
                200,
                {
                    "schema": "quotabot.release.v1",
                    "released": True,
                },
            )
            return
        _json_response(self, 404, {"error": "not found"})


class _FakeOpenAIHandler(_SilentHandler):
    bodies_seen: list[dict[str, Any]] = []

    def do_POST(self) -> None:
        if not self.path.endswith("/chat/completions"):
            _json_response(self, 404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length).decode("utf-8")
        body = json.loads(raw) if raw else {}
        type(self).bodies_seen.append(body)
        model = body.get("model")
        _json_response(
            self,
            200,
            {
                "id": "chatcmpl-quotabot-test",
                "object": "chat.completion",
                "created": 1782000000,
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "ok"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 1,
                    "completion_tokens": 1,
                    "total_tokens": 2,
                },
            },
        )


class _LoopbackServer:
    def __init__(self, handler: type[BaseHTTPRequestHandler]) -> None:
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self._server.server_port}"

    def __enter__(self) -> "_LoopbackServer":
        self._thread.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)


def _litellm_command() -> list[str]:
    try:
        import litellm  # noqa: F401
    except ImportError as error:
        raise unittest.SkipTest("litellm proxy package is not installed") from error

    return [sys.executable, "-c", "from litellm import run_server; run_server()"]


def _write_proxy_files(
    root: Path,
    quotabot_url: str,
    backend_url: str,
) -> tuple[Path, Path]:
    config = root / "config.yaml"
    routing = root / "quotabot-routing.yaml"
    shutil.copy2(INTEGRATION_DIR / "quotabot_router.py", root / "quotabot_router.py")
    model_template = """
  - model_name: {name}
    litellm_params:
      model: openai/{model}
      api_base: {backend}/v1
      api_key: test-key
"""
    config.write_text(
        "model_list:\n"
        + "".join(
            model_template.format(name=name, model=model, backend=backend_url)
            for name, model in {
                "frontier-coder": "fake-unrouted",
                "claude-sonnet": "fake-claude",
                "codex-gpt": "fake-codex",
                "ollama-qwen": "fake-local",
            }.items()
        )
        + "\nlitellm_settings:\n"
        + "  callbacks: quotabot_router.proxy_handler_instance\n"
        + "\ngeneral_settings:\n"
        + "  master_key: os.environ/LITELLM_MASTER_KEY\n",
        encoding="utf-8",
    )
    routing.write_text(
        f"""quotabot_url: {quotabot_url}
snapshot_ttl_seconds: 1
comfort_threshold: 15

models:
  frontier-coder:
    candidates:
      - deployment: claude-sonnet
        provider: claude
        spend: quota_plan
        overages_disabled: true
      - deployment: codex-gpt
        provider: codex
        spend: quota_plan
        overages_disabled: true
      - deployment: ollama-qwen
        local: true
""",
        encoding="utf-8",
    )
    return config, routing


def _wait_for_proxy(
    base_url: str,
    process: subprocess.Popen[bytes],
    log_path: Path,
    token: str,
) -> None:
    deadline = time.monotonic() + 60
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            output = log_path.read_text(encoding="utf-8", errors="replace")[-6000:]
            raise AssertionError(
                f"LiteLLM proxy exited early with {process.returncode}:\n{output}"
            )
        try:
            request = urllib.request.Request(
                f"{base_url}/health/liveness",
                headers={"Authorization": f"Bearer {token}"},
            )
            with urllib.request.urlopen(request, timeout=2) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(0.5)
    output = log_path.read_text(encoding="utf-8", errors="replace")[-6000:]
    raise AssertionError(
        f"LiteLLM proxy did not become ready: {last_error!r}\n{output}"
    )


def _post_json(
    url: str,
    payload: dict[str, Any],
    *,
    token: str | None = None,
) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        url,
        data=body,
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))


def _stop_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


@unittest.skipUnless(RUN_PROXY_TEST, "set QUOTABOT_RUN_LITELLM_PROXY_TEST=1")
class LiteLLMProxyIntegrationTest(unittest.TestCase):
    def test_proxy_routes_logical_model_with_real_precall_hook(self) -> None:
        command = _litellm_command()
        _FakeQuotabotHandler.requests_seen = 0
        _FakeQuotabotHandler.reservations_seen = 0
        _FakeQuotabotHandler.releases_seen = 0
        _FakeOpenAIHandler.bodies_seen = []

        with (
            _LoopbackServer(_FakeQuotabotHandler) as quotabot,
            _LoopbackServer(_FakeOpenAIHandler) as backend,
            tempfile.TemporaryDirectory(prefix="quotabot-litellm-") as temp,
        ):
            config, routing = _write_proxy_files(Path(temp), quotabot.url, backend.url)
            log_path = Path(temp) / "litellm-proxy.log"
            proxy_port = _free_port()
            proxy_url = f"http://127.0.0.1:{proxy_port}"
            master_key = "quotabot-integration-auth-value"
            env = os.environ.copy()
            env["QUOTABOT_ROUTING"] = str(routing)
            env["PYTHONPATH"] = (
                str(INTEGRATION_DIR) + os.pathsep + env.get("PYTHONPATH", "")
            )
            env["LITELLM_LOG"] = "ERROR"
            env["LITELLM_DONT_SHOW_FEEDBACK_BOX"] = "true"
            env["LITELLM_MASTER_KEY"] = master_key
            env["QUOTABOT_HTTP_TOKEN"] = _FakeQuotabotHandler.mutation_token
            env["NO_PROXY"] = "127.0.0.1,localhost"
            env["no_proxy"] = "127.0.0.1,localhost"
            env["PYTHONIOENCODING"] = "utf-8"
            env["PYTHONUTF8"] = "1"
            with log_path.open("wb") as log_file:
                process = subprocess.Popen(
                    command
                    + [
                        "--config",
                        str(config),
                        "--host",
                        "127.0.0.1",
                        "--port",
                        str(proxy_port),
                        "--num_workers",
                        "1",
                        "--telemetry",
                        "False",
                    ],
                    cwd=INTEGRATION_DIR,
                    env=env,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    creationflags=(
                        subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
                    ),
                    start_new_session=os.name != "nt",
                )
                try:
                    _wait_for_proxy(proxy_url, process, log_path, master_key)
                    with self.assertRaises(urllib.error.HTTPError) as denied:
                        _post_json(
                            f"{proxy_url}/v1/chat/completions",
                            {
                                "model": "frontier-coder",
                                "messages": [{"role": "user", "content": "hello"}],
                            },
                        )
                    denied_body = denied.exception.read().decode(
                        "utf-8",
                        errors="replace",
                    )
                    proxy_log = log_path.read_text(
                        encoding="utf-8",
                        errors="replace",
                    )[-6000:]
                    # LiteLLM 1.91.0 can turn its missing-key response into 500
                    # when the optional Prisma package is absent. Both outcomes
                    # must fail closed before the routing hook or model backend.
                    self.assertIn(
                        denied.exception.code,
                        {401, 500},
                        f"{denied_body}\n{proxy_log}",
                    )
                    self.assertEqual(0, _FakeQuotabotHandler.requests_seen)
                    self.assertFalse(_FakeOpenAIHandler.bodies_seen)
                    response = _post_json(
                        f"{proxy_url}/v1/chat/completions",
                        {
                            "model": "frontier-coder",
                            "messages": [{"role": "user", "content": "hello"}],
                        },
                        token=master_key,
                    )
                    release_deadline = time.monotonic() + 5
                    while (
                        _FakeQuotabotHandler.releases_seen < 1
                        and time.monotonic() < release_deadline
                    ):
                        time.sleep(0.05)
                finally:
                    _stop_process_tree(process)

        self.assertEqual("ok", response["choices"][0]["message"]["content"])
        self.assertGreaterEqual(_FakeQuotabotHandler.requests_seen, 1)
        self.assertEqual(_FakeQuotabotHandler.reservations_seen, 1)
        self.assertEqual(_FakeQuotabotHandler.releases_seen, 1)
        self.assertTrue(_FakeOpenAIHandler.bodies_seen)
        self.assertEqual("fake-claude", _FakeOpenAIHandler.bodies_seen[-1]["model"])


if __name__ == "__main__":
    unittest.main()
