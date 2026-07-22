#!/usr/bin/env python3
"""Launch a packaged desktop app and verify its native readiness signal."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


SCHEMA = "quotabot.desktop-readiness.v1"
REPORT_SCHEMA = "quotabot.desktop-readiness-report.v2"
BUNDLE_SCHEMA = "quotabot.desktop-bundle.v1"
READINESS_ENV = "QUOTABOT_DESKTOP_READINESS_FILE"
MAX_BUNDLE_ENTRIES = 4096
MAX_BUNDLE_BYTES = 512 * 1024 * 1024
MAX_LINK_TARGET_BYTES = 4096
HASH_CHUNK_BYTES = 1024 * 1024


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
            "--env",
            f"XDG_CONFIG_HOME={readiness_file.parent / 'config'}",
            str(app_bundle),
        ]
    return [str(executable)]


def isolated_config_environment(platform: str, config_root: Path) -> dict[str, str]:
    root = str(config_root)
    environment = {"XDG_CONFIG_HOME": root}
    if platform == "windows":
        environment.update({"LOCALAPPDATA": root, "APPDATA": root})
    return environment


def executable_sha256(executable: Path) -> str:
    digest = hashlib.sha256()
    with executable.open("rb") as source:
        for chunk in iter(lambda: source.read(HASH_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def desktop_bundle_root(executable: Path, platform: str) -> Path:
    if platform == "macos":
        app_bundle = executable.parent.parent.parent
        if app_bundle.suffix != ".app":
            raise RuntimeError(
                f"macOS desktop executable is not inside an app bundle: {executable}"
            )
        return app_bundle
    if platform in {"windows", "linux"}:
        return executable.parent
    raise RuntimeError(f"Unsupported desktop bundle platform: {platform}")


def _bundle_entries(
    root: Path,
    *,
    max_entries: int,
) -> list[tuple[str, str, Path]]:
    if max_entries <= 0:
        raise RuntimeError("Desktop bundle entry limit must be positive")
    pending = [root]
    entries: list[tuple[str, str, Path]] = []
    observed_entries = 0
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as iterator:
                for child in iterator:
                    observed_entries += 1
                    if observed_entries > max_entries:
                        raise RuntimeError(
                            f"Desktop bundle exceeds the {max_entries} entry limit"
                        )
                    path = Path(child.path)
                    relative = path.relative_to(root).as_posix()
                    if child.is_symlink():
                        entries.append(("link", relative, path))
                    elif child.is_dir(follow_symlinks=False):
                        pending.append(path)
                    elif child.is_file(follow_symlinks=False):
                        entries.append(("file", relative, path))
                    else:
                        raise RuntimeError(
                            f"Desktop bundle contains an unsupported entry: {relative}"
                        )
        except OSError as error:
            raise RuntimeError(
                f"Desktop bundle directory cannot be read: {directory.name}"
            ) from error
    return sorted(entries, key=lambda entry: os.fsencode(entry[1]))


def _hash_framed_bytes(digest: Any, value: bytes, *, width: int) -> None:
    digest.update(len(value).to_bytes(width, "big"))
    digest.update(value)


def _same_regular_file(first: os.stat_result, second: os.stat_result) -> bool:
    return (
        stat.S_ISREG(first.st_mode)
        and stat.S_ISREG(second.st_mode)
        and first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_size == second.st_size
        and first.st_mtime_ns == second.st_mtime_ns
    )


def desktop_bundle_identity(
    executable: Path,
    platform: str,
    *,
    max_entries: int = MAX_BUNDLE_ENTRIES,
    max_bytes: int = MAX_BUNDLE_BYTES,
) -> dict[str, Any]:
    if max_bytes <= 0:
        raise RuntimeError("Desktop bundle byte limit must be positive")
    root = desktop_bundle_root(executable, platform)
    if not root.is_dir():
        raise RuntimeError(f"Desktop bundle root not found: {root}")

    digest = hashlib.sha256()
    digest.update(BUNDLE_SCHEMA.encode("ascii") + b"\0")
    total_bytes = 0
    entries = _bundle_entries(root, max_entries=max_entries)
    for kind, relative, path in entries:
        relative_bytes = os.fsencode(relative)
        if kind == "link":
            try:
                target = os.fsencode(os.readlink(path))
            except OSError as error:
                raise RuntimeError(
                    f"Desktop bundle link cannot be read: {relative}"
                ) from error
            if len(target) > MAX_LINK_TARGET_BYTES:
                raise RuntimeError(
                    f"Desktop bundle link target is too long: {relative}"
                )
            digest.update(b"L")
            _hash_framed_bytes(digest, relative_bytes, width=4)
            _hash_framed_bytes(digest, target, width=4)
            continue

        try:
            before = path.stat(follow_symlinks=False)
        except OSError as error:
            raise RuntimeError(
                f"Desktop bundle file cannot be inspected: {relative}"
            ) from error
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError(f"Desktop bundle file changed type: {relative}")
        total_bytes += before.st_size
        if total_bytes > max_bytes:
            raise RuntimeError(f"Desktop bundle exceeds the {max_bytes} byte limit")

        digest.update(b"F")
        _hash_framed_bytes(digest, relative_bytes, width=4)
        digest.update(before.st_size.to_bytes(8, "big"))
        try:
            with path.open("rb") as source:
                opened = os.fstat(source.fileno())
                if not _same_regular_file(before, opened):
                    raise RuntimeError(
                        f"Desktop bundle file changed while hashing: {relative}"
                    )
                bytes_read = 0
                for chunk in iter(lambda: source.read(HASH_CHUNK_BYTES), b""):
                    bytes_read += len(chunk)
                    digest.update(chunk)
                closed = os.fstat(source.fileno())
        except OSError as error:
            raise RuntimeError(
                f"Desktop bundle file cannot be read: {relative}"
            ) from error
        if bytes_read != before.st_size or not _same_regular_file(before, closed):
            raise RuntimeError(f"Desktop bundle file changed while hashing: {relative}")
        try:
            after = path.stat(follow_symlinks=False)
        except OSError as error:
            raise RuntimeError(
                f"Desktop bundle file cannot be rechecked: {relative}"
            ) from error
        if not _same_regular_file(before, after):
            raise RuntimeError(f"Desktop bundle file changed while hashing: {relative}")

    return {
        "bundle_schema": BUNDLE_SCHEMA,
        "bundle_sha256": digest.hexdigest(),
        "bundle_entry_count": len(entries),
        "bundle_bytes": total_bytes,
    }


def assert_bundle_unchanged(
    expected: dict[str, Any],
    observed: dict[str, Any],
) -> None:
    if observed != expected:
        raise RuntimeError("Desktop bundle changed during readiness")


def validate_report_destination(path: Path, bundle_root: Path) -> None:
    destination = path.resolve()
    root = bundle_root.resolve()
    if destination == root or root in destination.parents:
        raise RuntimeError("Desktop readiness report must be outside the bundle")


def build_readiness_report(
    platform: str,
    launch_pid: int,
    executable: Path,
    bundle_identity: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema": REPORT_SCHEMA,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "platform": platform,
        "launch_pid": launch_pid,
        "launch_process_stopped": True,
        "executable_name": executable.name,
        "executable_sha256": executable_sha256(executable),
        **bundle_identity,
        "bundle_unchanged": True,
        "isolated_config": True,
        "window_ready": True,
        "tray_ready": True,
    }


def write_report(path: Path, payload: dict[str, Any]) -> None:
    parent = path.resolve().parent
    if not parent.is_dir():
        raise RuntimeError(f"Desktop readiness report directory not found: {parent}")
    temporary = parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        temporary.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        try:
            temporary.chmod(0o600)
        except OSError:
            pass
        temporary.replace(path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


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
    return result_code == 0 and rect.right > rect.left and rect.bottom > rect.top


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


def _read_json_if_ready(path: Path) -> Any:
    """Read a JSON file the desktop process may be writing concurrently.

    Returns the parsed object, or None when the file is not there yet, is
    momentarily share-locked (on Windows the app holds the handle while it
    writes, which surfaces as PermissionError), or is a partial write (invalid
    JSON). All three are "not ready yet, poll again" states rather than hard
    failures; the caller's deadline bounds the wait, so a genuinely stuck app
    still fails with a clear timeout message instead of a flaky read error.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def await_readiness(
    process: subprocess.Popen[bytes],
    readiness_file: Path,
    expected_platform: str,
    timeout_seconds: float,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    progress: dict[str, Any] = {}
    while time.monotonic() < deadline:
        payload = _read_json_if_ready(readiness_file)
        if payload is not None:
            if validate_payload(payload, expected_platform):
                return
            raise RuntimeError("Desktop readiness file contains an incomplete state")
        for component in ("window", "tray"):
            component_payload = _read_json_if_ready(
                Path(f"{readiness_file}.{component}.json")
            )
            if component_payload is None:
                continue
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
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
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
    parser.add_argument(
        "--report",
        type=Path,
        help="write a machine-readable readiness evidence report",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    executable = args.executable.resolve()
    if not executable.is_file():
        raise RuntimeError(f"Desktop executable not found: {executable}")
    if args.timeout <= 0:
        raise RuntimeError("Desktop readiness timeout must be positive")

    platform = host_platform()
    bundle_root = desktop_bundle_root(executable, platform)
    if args.report is not None:
        validate_report_destination(args.report, bundle_root)
    bundle_before = desktop_bundle_identity(executable, platform)
    launch_pid: int | None = None
    with tempfile.TemporaryDirectory(prefix="quotabot-desktop-readiness-") as raw_temp:
        temporary_directory = Path(raw_temp)
        readiness_file = temporary_directory / "readiness.json"
        log_file = temporary_directory / "desktop.log"
        command = launch_command(executable, platform, readiness_file)
        environment = os.environ.copy()
        environment[READINESS_ENV] = str(readiness_file)
        environment["QUOTABOT_DEMO"] = "1"
        environment.update(
            isolated_config_environment(platform, temporary_directory / "config")
        )

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
                launch_pid = process.pid
            except RuntimeError as error:
                output.flush()
                log_tail = log_file.read_text(encoding="utf-8", errors="replace")[
                    -4000:
                ]
                if log_tail.strip():
                    raise RuntimeError(
                        f"{error}\nDesktop log tail:\n{log_tail}"
                    ) from error
                raise
            finally:
                try:
                    if platform == "macos":
                        stop_macos_app(executable)
                finally:
                    stop_process(process)

        if launch_pid is None:
            raise RuntimeError("Desktop readiness evidence was not produced")
        if process.poll() is None:
            raise RuntimeError("Desktop launch process did not stop after readiness")
        bundle_after = desktop_bundle_identity(executable, platform)
        assert_bundle_unchanged(bundle_before, bundle_after)
        report = build_readiness_report(
            platform,
            launch_pid,
            executable,
            bundle_before,
        )

    if args.report is not None:
        write_report(args.report, report)

    print(f"Desktop window and tray readiness passed on {platform}.")
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
