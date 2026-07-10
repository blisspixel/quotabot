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
                        "headroom_percent": 72,
                        "available": True,
                    },
                    {
                        "provider": "codex",
                        "headroom_percent": 8,
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
            },
        )


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
        + "  callbacks: quotabot_router.proxy_handler_instance\n",
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
            with urllib.request.urlopen(
                f"{base_url}/health/liveness",
                timeout=2,
            ) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(0.5)
    output = log_path.read_text(encoding="utf-8", errors="replace")[-6000:]
    raise AssertionError(f"LiteLLM proxy did not become ready: {last_error!r}\n{output}")


def _post_json(url: str, payload: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
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
            env = os.environ.copy()
            env["QUOTABOT_ROUTING"] = str(routing)
            env["PYTHONPATH"] = (
                str(INTEGRATION_DIR) + os.pathsep + env.get("PYTHONPATH", "")
            )
            env["LITELLM_LOG"] = "ERROR"
            env["LITELLM_DONT_SHOW_FEEDBACK_BOX"] = "true"
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
                        subprocess.CREATE_NEW_PROCESS_GROUP
                        if os.name == "nt"
                        else 0
                    ),
                    start_new_session=os.name != "nt",
                )
                try:
                    _wait_for_proxy(proxy_url, process, log_path)
                    response = _post_json(
                        f"{proxy_url}/v1/chat/completions",
                        {
                            "model": "frontier-coder",
                            "messages": [{"role": "user", "content": "hello"}],
                        },
                    )
                finally:
                    _stop_process_tree(process)

        self.assertEqual("ok", response["choices"][0]["message"]["content"])
        self.assertGreaterEqual(_FakeQuotabotHandler.requests_seen, 1)
        self.assertTrue(_FakeOpenAIHandler.bodies_seen)
        self.assertEqual("fake-claude", _FakeOpenAIHandler.bodies_seen[-1]["model"])


if __name__ == "__main__":
    unittest.main()
