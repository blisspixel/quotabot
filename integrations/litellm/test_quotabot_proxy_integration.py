"""Real LiteLLM proxy integration coverage for the quotabot router.

The test runs only when explicitly enabled because it starts the LiteLLM proxy
and requires the optional proxy dependencies. It stays fully local: the quota
server and the OpenAI-compatible model backend are loopback test doubles.
"""

from __future__ import annotations

import contextlib
import base64
import ctypes
import ctypes.wintypes as wintypes
import hashlib
import hmac
import ipaddress
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
import unittest.mock
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator


INTEGRATION_DIR = Path(__file__).resolve().parent
RUN_PROXY_TEST = os.environ.get("QUOTABOT_RUN_LITELLM_PROXY_TEST") == "1"


class _JobBasicLimits(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", wintypes.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wintypes.DWORD),
        ("SchedulingClass", wintypes.DWORD),
    ]


class _JobIoCounters(ctypes.Structure):
    _fields_ = [
        (name, ctypes.c_uint64)
        for name in (
            "ReadOperationCount",
            "WriteOperationCount",
            "OtherOperationCount",
            "ReadTransferCount",
            "WriteTransferCount",
            "OtherTransferCount",
        )
    ]


class _JobExtendedLimits(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _JobBasicLimits),
        ("IoInfo", _JobIoCounters),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class _JobAccounting(ctypes.Structure):
    _fields_ = [
        ("TotalUserTime", ctypes.c_int64),
        ("TotalKernelTime", ctypes.c_int64),
        ("ThisPeriodTotalUserTime", ctypes.c_int64),
        ("ThisPeriodTotalKernelTime", ctypes.c_int64),
        ("TotalPageFaultCount", wintypes.DWORD),
        ("TotalProcesses", wintypes.DWORD),
        ("ActiveProcesses", wintypes.DWORD),
        ("TotalTerminatedProcesses", wintypes.DWORD),
    ]


class _WindowsJob:
    """Own test descendants without relying on process-tree enumeration."""

    def __init__(self) -> None:
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "CreateJobObjectW": ([ctypes.c_void_p, wintypes.LPCWSTR], wintypes.HANDLE),
            "SetInformationJobObject": (
                [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD],
                wintypes.BOOL,
            ),
            "QueryInformationJobObject": (
                [
                    wintypes.HANDLE,
                    ctypes.c_int,
                    ctypes.c_void_p,
                    wintypes.DWORD,
                    ctypes.c_void_p,
                ],
                wintypes.BOOL,
            ),
            "AssignProcessToJobObject": (
                [wintypes.HANDLE, wintypes.HANDLE],
                wintypes.BOOL,
            ),
            "IsProcessInJob": (
                [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)],
                wintypes.BOOL,
            ),
            "OpenProcess": (
                [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD],
                wintypes.HANDLE,
            ),
            "TerminateJobObject": ([wintypes.HANDLE, wintypes.UINT], wintypes.BOOL),
            "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
            "CreateFileW": (
                [
                    wintypes.LPCWSTR,
                    wintypes.DWORD,
                    wintypes.DWORD,
                    ctypes.c_void_p,
                    wintypes.DWORD,
                    wintypes.DWORD,
                    wintypes.HANDLE,
                ],
                wintypes.HANDLE,
            ),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self._kernel32, name)
            function.argtypes = arguments
            function.restype = result
        self._handle = self._kernel32.CreateJobObjectW(None, None)
        if not self._handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = _JobExtendedLimits()
        limits.BasicLimitInformation.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE
        try:
            if not self._kernel32.SetInformationJobObject(
                self._handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)
            ):
                raise ctypes.WinError(ctypes.get_last_error())
        except BaseException:
            self.close()
            raise

    def assign(self, pid: int) -> None:
        # Set quota, terminate and query access apply only to our gated child.
        process = self._kernel32.OpenProcess(0x0100 | 0x0001 | 0x1000, False, pid)
        if not process:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            member = wintypes.BOOL()
            if not self._kernel32.IsProcessInJob(
                process, self._handle, ctypes.byref(member)
            ):
                raise ctypes.WinError(ctypes.get_last_error())
            if not member.value and not self._kernel32.AssignProcessToJobObject(
                self._handle, process
            ):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            if not self._kernel32.CloseHandle(process):
                raise ctypes.WinError(ctypes.get_last_error())

    def active_processes(self) -> int:
        accounting = _JobAccounting()
        if not self._kernel32.QueryInformationJobObject(
            self._handle, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        return int(accounting.ActiveProcesses)

    def terminate_and_wait(self) -> None:
        if not self._kernel32.TerminateJobObject(self._handle, 1):
            raise ctypes.WinError(ctypes.get_last_error())
        deadline = time.monotonic() + 10
        while self.active_processes():
            if time.monotonic() >= deadline:
                raise TimeoutError("Owned Windows job did not terminate its children")
            time.sleep(0.01)

    def close(self) -> None:
        if self._handle:
            handle, self._handle = self._handle, None
            if not self._kernel32.CloseHandle(handle):
                raise ctypes.WinError(ctypes.get_last_error())

    def wait_for_log_release(self, log_path: Path) -> None:
        # Job accounting can reach zero before asynchronous file-handle rundown.
        # Prove exclusive access before TemporaryDirectory tries to remove it.
        deadline = time.monotonic() + 10
        while True:
            handle = self._kernel32.CreateFileW(
                str(log_path), 0x80000000, 0, None, 3, 0x80, None
            )
            if handle != ctypes.c_void_p(-1).value:
                if not self._kernel32.CloseHandle(handle):
                    raise ctypes.WinError(ctypes.get_last_error())
                return
            error = ctypes.get_last_error()
            if error != 32:
                raise ctypes.WinError(error)
            if time.monotonic() >= deadline:
                raise TimeoutError("Owned Windows children did not release their log")
            time.sleep(0.01)


def _wait_for_process_identity(process: subprocess.Popen[bytes], log_path: Path) -> int:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        with log_path.open("rb") as log:
            line = log.readline(64)
        if line.endswith(b"\n"):
            prefix, separator, raw_pid = line.rstrip(b"\r\n").partition(b" ")
            if (
                prefix != b"quotabot-owned-process-v1"
                or not separator
                or not raw_pid.isdigit()
                or int(raw_pid) <= 0
            ):
                raise RuntimeError("Owned test process returned an invalid identity")
            return int(raw_pid)
        if process.poll() is not None:
            raise RuntimeError("Owned test process exited before its startup gate")
        time.sleep(0.01)
    raise TimeoutError("Owned test process did not reach its startup gate")


@contextlib.contextmanager
def _owned_process(
    command: list[str], *, cwd: Path, env: dict[str, str], log_path: Path
) -> Iterator[subprocess.Popen[bytes]]:
    job = _WindowsJob() if os.name == "nt" else None
    try:
        with log_path.open("wb") as log_file:
            if job is not None:
                if len(command) < 3 or command[1] != "-c":
                    raise ValueError("Windows test ownership requires a Python command")
                # A venv launcher can create the real interpreter before assignment.
                # No installed CLI import or child work occurs until both are owned.
                bootstrap = (
                    "import os, sys\n"
                    "print(f'quotabot-owned-process-v1 {os.getpid()}', flush=True)\n"
                    "if sys.stdin.buffer.read(1) != b'g':\n"
                    "    raise SystemExit(1)\n"
                )
                command = [command[0], "-c", bootstrap + command[2], *command[3:]]
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=env,
                stdin=subprocess.PIPE if job is not None else subprocess.DEVNULL,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                creationflags=(
                    subprocess.CREATE_NEW_PROCESS_GROUP if job is not None else 0
                ),
                start_new_session=job is None,
            )
            try:
                if job is not None:
                    job.assign(process.pid)
                    job.assign(_wait_for_process_identity(process, log_path))
                    if process.stdin is None:
                        raise RuntimeError("Owned test process has no startup gate")
                    process.stdin.write(b"g")
                    process.stdin.flush()
                yield process
            finally:
                try:
                    if process.stdin is not None:
                        process.stdin.close()
                finally:
                    _stop_process_tree(process, job)
    finally:
        if job is not None:
            job.close()
            if log_path.exists():
                job.wait_for_log_release(log_path)


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


def _server_proof(handler: BaseHTTPRequestHandler, token: str, nonce: str) -> str:
    peer = handler.connection.getsockname()
    address = ipaddress.ip_address(str(peer[0]).split("%", 1)[0])
    encoded = base64.urlsafe_b64encode(address.packed).rstrip(b"=").decode("ascii")
    endpoint = f"{encoded}:{int(peer[1])}"
    message = f"quotabot-local-server-proof-v1\n{nonce}\n{endpoint}"
    return hmac.new(
        token.encode("utf-8"),
        message.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


class _SilentHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        return None


class _FakeQuotabotHandler(_SilentHandler):
    protocol_version = "HTTP/1.1"
    requests_seen = 0
    reservations_seen = 0
    releases_seen = 0
    mutation_token = "quotabot-proxy-mutation-token-012345"

    def do_GET(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/auth/prove":
            nonce = urllib.parse.parse_qs(parsed.query).get("nonce", [""])[0]
            _json_response(
                self,
                200,
                {
                    "schema": "quotabot.local-server-proof.v1",
                    "nonce": nonce,
                    "proof": _server_proof(self, type(self).mutation_token, nonce),
                },
            )
            return
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
        with unittest.mock.patch.dict(
            os.environ, {"LITELLM_LOCAL_MODEL_COST_MAP": "True"}
        ):
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
    shutil.copy2(INTEGRATION_DIR / "local_metadata.py", root / "local_metadata.py")
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


def _stop_process_tree(
    process: subprocess.Popen[bytes], job: _WindowsJob | None
) -> None:
    if job is not None:
        job.terminate_and_wait()
    else:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if job is not None:
            process.kill()
            process.wait(timeout=10)
            raise RuntimeError("Owned Windows launcher did not exit after cleanup")
        else:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


@unittest.skipUnless(os.name == "nt", "Windows job process ownership")
class ProxyProcessOwnershipTest(unittest.TestCase):
    def test_cleanup_still_runs_if_startup_pipe_close_fails(self) -> None:
        process = unittest.mock.Mock(pid=31415)
        process.stdin.close.side_effect = BrokenPipeError("synthetic closed gate")
        process.wait.return_value = 0
        job = unittest.mock.Mock()
        with tempfile.TemporaryDirectory(prefix="quotabot-proxy-cleanup-") as temp:
            with (
                unittest.mock.patch(f"{__name__}._WindowsJob", return_value=job),
                unittest.mock.patch(
                    f"{__name__}._wait_for_process_identity", return_value=31415
                ),
                unittest.mock.patch(
                    f"{__name__}.subprocess.Popen", return_value=process
                ),
                self.assertRaises(BrokenPipeError),
            ):
                with _owned_process(
                    [sys.executable, "-c", "pass"],
                    cwd=Path(temp),
                    env=os.environ.copy(),
                    log_path=Path(temp) / "cleanup.log",
                ):
                    pass
        job.terminate_and_wait.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=10)
        job.close.assert_called_once_with()

    def test_cleanup_stops_child_after_launcher_has_exited(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quotabot-proxy-ownership-") as temp:
            log_path = Path(temp) / "owned-child.log"
            child_source = (
                "import time\nprint('owned child ready', flush=True)\ntime.sleep(60)\n"
            )
            parent_source = (
                "import subprocess, sys\n"
                f"subprocess.Popen([sys.executable, '-c', {child_source!r}], "
                "stdout=sys.stdout, stderr=sys.stderr)\n"
            )
            with _owned_process(
                [sys.executable, "-c", parent_source],
                cwd=Path(temp),
                env=os.environ.copy(),
                log_path=log_path,
            ) as process:
                self.assertEqual(0, process.wait(timeout=10))
                deadline = time.monotonic() + 10
                while b"owned child ready" not in log_path.read_bytes():
                    if time.monotonic() >= deadline:
                        self.fail("Owned descendant did not reach its ready state")
                    time.sleep(0.01)
                # The descendant still holds this file after its launcher exits.
                with self.assertRaises(PermissionError):
                    log_path.rename(Path(temp) / "still-running.log")
            log_path.rename(Path(temp) / "released.log")


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
            env["PYTHONPATH"] = str(Path(temp))
            env["LITELLM_LOG"] = "ERROR"
            env["LITELLM_LOCAL_MODEL_COST_MAP"] = "True"
            env["LITELLM_DONT_SHOW_FEEDBACK_BOX"] = "true"
            env["LITELLM_MASTER_KEY"] = master_key
            env["QUOTABOT_HTTP_TOKEN"] = _FakeQuotabotHandler.mutation_token
            env["NO_PROXY"] = "127.0.0.1,localhost"
            env["no_proxy"] = "127.0.0.1,localhost"
            env["PYTHONIOENCODING"] = "utf-8"
            env["PYTHONUTF8"] = "1"
            with _owned_process(
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
                log_path=log_path,
            ) as process:
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
                try:
                    response = _post_json(
                        f"{proxy_url}/v1/chat/completions",
                        {
                            "model": "frontier-coder",
                            "messages": [{"role": "user", "content": "hello"}],
                        },
                        token=master_key,
                    )
                except TimeoutError:
                    proxy_log = log_path.read_text(
                        encoding="utf-8",
                        errors="replace",
                    )[-6000:]
                    self.fail(
                        "LiteLLM proxy timed out routing the authenticated "
                        f"completion:\n{proxy_log}"
                    )
                release_deadline = time.monotonic() + 5
                while (
                    _FakeQuotabotHandler.releases_seen < 1
                    and time.monotonic() < release_deadline
                ):
                    time.sleep(0.05)
        self.assertEqual("ok", response["choices"][0]["message"]["content"])
        self.assertGreaterEqual(_FakeQuotabotHandler.requests_seen, 1)
        self.assertEqual(_FakeQuotabotHandler.reservations_seen, 1)
        self.assertEqual(_FakeQuotabotHandler.releases_seen, 1)
        self.assertTrue(_FakeOpenAIHandler.bodies_seen)
        self.assertEqual("fake-claude", _FakeOpenAIHandler.bodies_seen[-1]["model"])


if __name__ == "__main__":
    unittest.main()
