#!/usr/bin/env python3
"""Launch a packaged desktop app and verify its native readiness signal."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any


SCHEMA = "quotabot.desktop-readiness.v1"
READINESS_ENV = "QUOTABOT_DESKTOP_READINESS_FILE"


def host_platform() -> str:
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    raise RuntimeError(f"Unsupported desktop smoke-test platform: {sys.platform}")


def launch_command(
    executable: Path,
    platform: str,
    readiness_file: Path,
) -> list[str]:
    if platform == "linux":
        for dependency in ("dbus-run-session", "xvfb-run"):
            if shutil.which(dependency) is None:
                raise RuntimeError(
                    f"Required desktop smoke dependency not found: {dependency}"
            )
        return ["dbus-run-session", "--", "xvfb-run", "-a", str(executable)]
    if platform == "macos":
        app_bundle = executable.parent.parent.parent
        if app_bundle.suffix != ".app":
            raise RuntimeError(
                f"macOS desktop executable is not inside an app bundle: {executable}"
            )
        return [
            "/usr/bin/open",
            "-n",
            "-W",
            "--env",
            f"{READINESS_ENV}={readiness_file}",
            "--env",
            "QUOTABOT_DEMO=1",
            str(app_bundle),
        ]
    return [str(executable)]


def validate_payload(payload: Any, expected_platform: str) -> bool:
    if not isinstance(payload, dict):
        raise RuntimeError("Desktop readiness payload must be a JSON object")
    if set(payload) != {"schema", "window_ready", "tray_ready", "platform"}:
        raise RuntimeError("Desktop readiness payload fields are invalid")
    if payload["schema"] != SCHEMA or payload["platform"] != expected_platform:
        raise RuntimeError("Desktop readiness schema or platform is invalid")
    window_ready = payload["window_ready"]
    tray_ready = payload["tray_ready"]
    if type(window_ready) is not bool or (
        tray_ready is not None and type(tray_ready) is not bool
    ):
        raise RuntimeError("Desktop readiness states must be boolean or null")
    if tray_ready is False:
        raise RuntimeError(
            "Desktop app reported failed tray initialization: "
            f"{json.dumps(payload, sort_keys=True)}"
        )
    return window_ready and tray_ready is True


def valid_windows_tray_rect(result_code: int, rect: Any) -> bool:
    return (
        result_code == 0
        and rect.right > rect.left
        and rect.bottom > rect.top
    )


def windows_tray_rect(process_id: int) -> tuple[int, int, int, int] | None:
    if os.name != "nt":
        raise RuntimeError("Windows tray inspection requires Windows")

    import ctypes
    import ctypes.wintypes

    wintypes = ctypes.wintypes

    class Guid(ctypes.Structure):
        _fields_ = [
            ("data1", wintypes.DWORD),
            ("data2", wintypes.WORD),
            ("data3", wintypes.WORD),
            ("data4", wintypes.BYTE * 8),
        ]

    class NotifyIconIdentifier(ctypes.Structure):
        _fields_ = [
            ("cb_size", wintypes.DWORD),
            ("window", wintypes.HWND),
            ("icon_id", wintypes.UINT),
            ("guid_item", Guid),
        ]

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    window_handles: list[int] = []
    enum_callback = ctypes.WINFUNCTYPE(
        wintypes.BOOL,
        wintypes.HWND,
        wintypes.LPARAM,
    )

    @enum_callback
    def collect_process_window(window: int, _parameter: int) -> bool:
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
        if owner.value == process_id:
            window_handles.append(window)
        return True

    user32.EnumWindows.argtypes = [enum_callback, wintypes.LPARAM]
    user32.EnumWindows.restype = wintypes.BOOL
    if not user32.EnumWindows(collect_process_window, 0):
        return None

    shell32.Shell_NotifyIconGetRect.argtypes = [
        ctypes.POINTER(NotifyIconIdentifier),
        ctypes.POINTER(wintypes.RECT),
    ]
    shell32.Shell_NotifyIconGetRect.restype = ctypes.c_long
    for window in window_handles:
        identifier = NotifyIconIdentifier(
            cb_size=ctypes.sizeof(NotifyIconIdentifier),
            window=window,
            icon_id=1,
            guid_item=Guid(),
        )
        rect = wintypes.RECT()
        result_code = shell32.Shell_NotifyIconGetRect(
            ctypes.byref(identifier),
            ctypes.byref(rect),
        )
        if valid_windows_tray_rect(result_code, rect):
            return rect.left, rect.top, rect.right, rect.bottom
    return None


def await_windows_tray(
    process: subprocess.Popen[bytes], timeout_seconds: float = 10.0
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if windows_tray_rect(process.pid) is not None:
            return
        return_code = process.poll()
        if return_code is not None:
            raise RuntimeError(
                "Desktop app exited before Windows confirmed its tray icon "
                f"with code {return_code}"
            )
        time.sleep(0.2)
    raise RuntimeError(
        "Windows Shell_NotifyIconGetRect did not confirm a registered tray icon"
    )


def await_readiness(
    process: subprocess.Popen[bytes],
    readiness_file: Path,
    expected_platform: str,
    timeout_seconds: float,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    progress: dict[str, Any] = {}
    while time.monotonic() < deadline:
        try:
            payload_text = readiness_file.read_text(encoding="utf-8")
        except FileNotFoundError:
            payload_text = None
        except OSError as error:
            raise RuntimeError("Desktop readiness file could not be read") from error
        if payload_text is not None:
            try:
                payload = json.loads(payload_text)
            except json.JSONDecodeError as error:
                raise RuntimeError(
                    "Desktop readiness file is not valid UTF-8 JSON"
                ) from error
            if validate_payload(payload, expected_platform):
                return
            raise RuntimeError("Desktop readiness file contains an incomplete state")
        for component in ("window", "tray"):
            progress_file = Path(f"{readiness_file}.{component}.json")
            try:
                progress_text = progress_file.read_text(encoding="utf-8")
            except FileNotFoundError:
                continue
            except OSError as error:
                raise RuntimeError(
                    f"Desktop {component} progress file could not be read"
                ) from error
            try:
                component_payload = json.loads(progress_text)
            except json.JSONDecodeError as error:
                raise RuntimeError(
                    f"Desktop {component} progress file is not valid UTF-8 JSON"
                ) from error
            validate_payload(component_payload, expected_platform)
            progress[component] = component_payload
        return_code = process.poll()
        if return_code is not None:
            raise RuntimeError(
                f"Desktop app exited before reporting readiness with code {return_code}"
            )
        time.sleep(0.2)
    detail = (
        "no readiness state was published"
        if not progress
        else f"progress was {json.dumps(progress, sort_keys=True)}"
    )
    raise RuntimeError(
        f"Desktop app did not report readiness within {timeout_seconds:g} seconds; "
        f"{detail}"
    )


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if os.name == "nt":
        if process.poll() is None:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        return

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        process.wait(timeout=5)


def macos_app_process_ids(process_table: str, executable: Path) -> list[int]:
    command_prefix = f"{executable} "
    process_ids: list[int] = []
    for line in process_table.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        raw_process_id, command = fields
        if command == str(executable) or command.startswith(command_prefix):
            try:
                process_ids.append(int(raw_process_id))
            except ValueError:
                continue
    return process_ids


def stop_macos_app(executable: Path) -> None:
    process_table = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        check=True,
        capture_output=True,
        text=True,
    )
    for process_id in macos_app_process_ids(process_table.stdout, executable):
        try:
            os.kill(process_id, signal.SIGTERM)
        except ProcessLookupError:
            continue


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=45.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    executable = args.executable.resolve()
    if not executable.is_file():
        raise RuntimeError(f"Desktop executable not found: {executable}")
    if args.timeout <= 0:
        raise RuntimeError("Desktop readiness timeout must be positive")

    platform = host_platform()
    with tempfile.TemporaryDirectory(prefix="quotabot-desktop-readiness-") as raw_temp:
        temporary_directory = Path(raw_temp)
        readiness_file = temporary_directory / "readiness.json"
        log_file = temporary_directory / "desktop.log"
        command = launch_command(executable, platform, readiness_file)
        environment = os.environ.copy()
        environment[READINESS_ENV] = str(readiness_file)
        environment["QUOTABOT_DEMO"] = "1"

        with log_file.open("wb") as output:
            process = subprocess.Popen(
                command,
                cwd=executable.parent,
                env=environment,
                stdout=output,
                stderr=subprocess.STDOUT,
                start_new_session=os.name != "nt",
            )
            try:
                await_readiness(
                    process,
                    readiness_file,
                    platform,
                    args.timeout,
                )
                if platform == "windows":
                    await_windows_tray(process)
            except RuntimeError as error:
                output.flush()
                log_tail = log_file.read_text(
                    encoding="utf-8", errors="replace"
                )[-4000:]
                if log_tail.strip():
                    raise RuntimeError(f"{error}\nDesktop log tail:\n{log_tail}") from error
                raise
            finally:
                try:
                    if platform == "macos":
                        stop_macos_app(executable)
                finally:
                    stop_process(process)

    print(f"Desktop window and tray readiness passed on {platform}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
