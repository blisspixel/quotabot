"""Refresh and remove the local Omarchy display snapshot.

The collector runs the existing quotabot CLI. It asks for `quotabot --json`
and `quotabot suggest --json`, then writes a redacted display file. It does
not call a model, does not switch a harness account, and does not write
Omarchy's agent usage directory.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path


def _load_display():
    name = "quotabot_omarchy_display"
    existing = sys.modules.get(name)
    if existing is not None:
        return existing
    path = Path(__file__).resolve().parent / "display.py"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


display = _load_display()

DISPLAY_NAME = "omarchy-display.json"
ALIAS_NAME = "alias.key"
LOCK_NAME = ".refresh.lock"
PLUGIN_ID = display.PLUGIN_ID
MAX_BYTES = 2 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 120.0
SNAPSHOT_ARGS = ("--json",)
SUGGEST_ARGS = ("suggest", "--json")

Runner = Callable[[Sequence[str], float], "CommandResult"]


@dataclass(frozen=True)
class CommandResult:
    """One finished quotabot invocation, without a retained oversized body."""

    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool


@dataclass(frozen=True)
class RefreshResult:
    """The display record written by one refresh, plus the commands that ran."""

    display: dict[str, object]
    commands: tuple[tuple[str, ...], ...]
    wrote: bool


def default_state_dir() -> Path:
    override = os.environ.get("QUOTABOT_OMARCHY_STATE_DIR", "").strip()
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(xdg) if xdg else Path.home() / ".local" / "state"
    return base / "quotabot"


def default_plugin_dir() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME", "").strip()
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "omarchy" / "plugins" / PLUGIN_ID


def default_agents_dir() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(xdg) if xdg else Path.home() / ".local" / "state"
    return base / "omarchy" / "agents" / "usage"


def display_path(state_dir: Path) -> Path:
    return state_dir / DISPLAY_NAME


def load_display(state_dir: Path) -> dict[str, object] | None:
    """Read the last display file. This never runs quotabot."""
    path = display_path(state_dir)
    if path.is_symlink() or not path.is_file():
        return None
    try:
        payload = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if len(payload.encode("utf-8")) > MAX_BYTES:
        return None
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict) or parsed.get("schema") != display.SCHEMA:
        return None
    return {str(key): value for key, value in parsed.items()}


def refresh(
    *,
    state_dir: Path,
    executable: Sequence[str] | None = None,
    runner: Runner | None = None,
    now: int | None = None,
    home: Path | None = None,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> RefreshResult:
    """Collect quotabot JSON and atomically replace the display snapshot."""
    moment = int(now if now is not None else time.time())
    home_path = home if home is not None else Path.home()
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        failed = display.preserve_failure(
            None,
            "state directory is unusable",
            now=moment,
            home=home_path,
        )
        return RefreshResult(failed, (), False)
    previous = load_display(state_dir)
    lock_path = state_dir / LOCK_NAME
    lock = _acquire_lock(lock_path, stale_after=timeout_seconds + 5)
    if lock is None:
        failed = display.preserve_failure(
            previous,
            "refresh already running",
            now=moment,
            home=home_path,
        )
        wrote = _write_display(state_dir, failed)
        return RefreshResult(failed, (), wrote)
    try:
        return _refresh_locked(
            state_dir=state_dir,
            executable=executable,
            runner=runner,
            now=moment,
            home=home_path,
            timeout_seconds=timeout_seconds,
            previous=previous,
        )
    finally:
        _release_lock(lock, lock_path)


def uninstall(
    *,
    state_dir: Path,
    plugin_dir: Path | None = None,
    agents_dir: Path | None = None,
) -> dict[str, object]:
    """Remove quotabot's Omarchy files and leave stock agent records untouched."""
    removed: list[str] = []
    skipped: list[str] = []
    preserved = _agent_names(agents_dir)
    if _paths_conflict(state_dir, plugin_dir, agents_dir):
        return {
            "removed": [],
            "preserved_agents": preserved,
            "skipped": ["refused: state, plugin, and agent paths must stay distinct"],
        }
    for name in (DISPLAY_NAME, ALIAS_NAME, LOCK_NAME):
        path = state_dir / name
        if _unlink_file(path):
            removed.append(str(path))
    if plugin_dir is None:
        skipped.append("plugin directory not requested")
    elif plugin_dir.is_symlink():
        skipped.append("plugin directory is a symlink")
    elif not plugin_dir.exists():
        skipped.append("plugin directory is absent")
    elif not _owned_plugin(plugin_dir):
        skipped.append("plugin manifest is not blisspixel.quotabot")
    else:
        _remove_tree(plugin_dir)
        removed.append(str(plugin_dir))
    after = _agent_names(agents_dir)
    if after != preserved:
        raise RuntimeError("uninstall changed an agent usage record")
    return {
        "removed": removed,
        "preserved_agents": preserved,
        "skipped": skipped,
    }


def run_command(argv: Sequence[str], timeout: float) -> CommandResult:
    """Run one argv list. The command is never a shell string."""
    arguments = tuple(argv)
    try:
        completed = subprocess.run(
            list(arguments),
            check=False,
            capture_output=True,
            timeout=timeout,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except subprocess.TimeoutExpired:
        return CommandResult(arguments, 124, "", "timeout", True)
    except OSError as error:
        detail = error.strerror or "command failed to start"
        return CommandResult(arguments, 127, "", detail, False)
    stdout = completed.stdout or ""
    stderr = completed.stderr or ""
    if (
        len(stdout.encode("utf-8")) > MAX_BYTES
        or len(stderr.encode("utf-8")) > MAX_BYTES
    ):
        return CommandResult(arguments, 75, "", "oversized response", False)
    return CommandResult(arguments, int(completed.returncode), stdout, stderr, False)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="quotabot-omarchy")
    subcommands = parser.add_subparsers(dest="command", required=True)
    refresh_parser = subcommands.add_parser("refresh")
    refresh_parser.add_argument("--quotabot", type=Path)
    refresh_parser.add_argument("--state-dir", type=Path)
    show_parser = subcommands.add_parser("show")
    show_parser.add_argument("--state-dir", type=Path)
    uninstall_parser = subcommands.add_parser("uninstall")
    uninstall_parser.add_argument("--state-dir", type=Path)
    uninstall_parser.add_argument("--plugin-dir", type=Path)
    uninstall_parser.add_argument("--agents-dir", type=Path)
    args = parser.parse_args(list(sys.argv[1:] if argv is None else argv))
    state_dir = args.state_dir or default_state_dir()
    if args.command == "show":
        current = load_display(state_dir)
        if current is None:
            print(
                '{"schema":"quotabot.omarchy.v1","read_ok":false,"read_error":"no snapshot"}'
            )
            return 2
        print(_dump(current))
        return 0
    if args.command == "uninstall":
        report = uninstall(
            state_dir=state_dir,
            plugin_dir=args.plugin_dir,
            agents_dir=args.agents_dir,
        )
        print(_dump(report))
        return 0
    executable = None
    if args.quotabot is not None:
        binary = args.quotabot.expanduser()
        if not binary.is_file() or binary.is_symlink():
            print("quotabot executable must be a regular file", file=sys.stderr)
            return 2
        executable = (str(binary),)
    result = refresh(state_dir=state_dir, executable=executable)
    if result.wrote:
        print(_dump(result.display))
    return 0 if result.wrote else 1


def _refresh_locked(
    *,
    state_dir: Path,
    executable: Sequence[str] | None,
    runner: Runner | None,
    now: int,
    home: Path,
    timeout_seconds: float,
    previous: dict[str, object] | None,
) -> RefreshResult:
    command = _executable(executable)
    invoke = runner or run_command
    if command is None:
        failed = display.preserve_failure(
            previous,
            "quotabot executable was not found",
            now=now,
            home=home,
        )
        return RefreshResult(failed, (), _write_display(state_dir, failed))
    snapshot_argv = (*command, *SNAPSHOT_ARGS)
    suggest_argv = (*command, *SUGGEST_ARGS)
    snapshot_result = invoke(snapshot_argv, timeout_seconds)
    suggest_result = invoke(suggest_argv, timeout_seconds)
    commands = (snapshot_result.argv, suggest_result.argv)
    snapshot, snapshot_error = _parse_output(
        snapshot_result,
        expected_schema=display.SNAPSHOT_SCHEMA,
    )
    suggestion, suggestion_error = _parse_output(
        suggest_result,
        expected_schema=display.SUGGEST_SCHEMA,
    )
    if snapshot is None or suggestion is None:
        failed = display.preserve_failure(
            previous,
            snapshot_error or suggestion_error or "refresh failed",
            now=now,
            home=home,
        )
        return RefreshResult(failed, commands, _write_display(state_dir, failed))
    try:
        alias_key = _alias_key(state_dir)
    except OSError:
        failed = display.preserve_failure(
            previous,
            "alias key is unusable",
            now=now,
            home=home,
        )
        return RefreshResult(failed, commands, _write_display(state_dir, failed))
    record = display.build_display(
        snapshot,
        suggestion,
        now=now,
        alias_key=alias_key,
        home=home,
    )
    return RefreshResult(record, commands, _write_display(state_dir, record))


def _executable(explicit: Sequence[str] | None) -> tuple[str, ...] | None:
    if explicit is not None:
        if not explicit or any(not part for part in explicit):
            return None
        return tuple(explicit)
    override = os.environ.get("QUOTABOT_BIN", "").strip()
    candidate = Path(override) if override else _which("quotabot")
    if candidate is None or not candidate.is_file() or candidate.is_symlink():
        return None
    return (str(candidate),)


def _which(name: str) -> Path | None:
    for raw in os.environ.get("PATH", "").split(os.pathsep):
        if not raw:
            continue
        candidate = Path(raw) / name
        if candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None


def _parse_output(
    result: CommandResult,
    *,
    expected_schema: str,
) -> tuple[dict[str, object] | None, str | None]:
    if result.timed_out:
        return None, "quotabot timed out"
    if result.returncode != 0:
        detail = display.scrub_text(result.stderr, home=Path.home())[:120]
        suffix = f": {detail}" if detail else ""
        return None, f"quotabot exited {result.returncode}{suffix}"
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, "quotabot returned invalid json"
    if not isinstance(parsed, dict) or parsed.get("schema") != expected_schema:
        return None, "quotabot returned an unexpected schema"
    return {str(key): value for key, value in parsed.items()}, None


def _alias_key(state_dir: Path) -> bytes:
    path = state_dir / ALIAS_NAME
    if path.is_symlink():
        raise OSError("alias key must not be a symlink")
    if path.exists():
        data = path.read_bytes()
        if len(data) != 32:
            raise OSError("alias key has an unexpected length")
        return data
    # Windows text mode expands newline bytes inside a random binary key.
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        key = os.urandom(32)
        os.write(descriptor, key)
    finally:
        os.close(descriptor)
    return key


def _write_display(state_dir: Path, record: Mapping[str, object]) -> bool:
    path = display_path(state_dir)
    temporary = path.with_name(f"{DISPLAY_NAME}.tmp")
    if path.is_symlink() or temporary.is_symlink():
        return False
    payload = _dump(record)
    if len(payload.encode("utf-8")) > MAX_BYTES:
        return False
    try:
        temporary.write_text(payload, encoding="utf-8", newline="\n")
        os.replace(temporary, path)
    except OSError:
        return False
    return True


def _dump(record: Mapping[str, object]) -> str:
    return json.dumps(record, indent=2, sort_keys=True, ensure_ascii=True)


def _acquire_lock(path: Path, *, stale_after: float) -> int | None:
    if path.is_symlink():
        return None
    if path.exists():
        try:
            age = time.time() - path.stat().st_mtime
        except OSError:
            return None
        if age <= stale_after:
            return None
        try:
            path.unlink()
        except OSError:
            return None
    try:
        return os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except OSError:
        return None


def _release_lock(descriptor: int, path: Path) -> None:
    try:
        os.close(descriptor)
    except OSError:
        pass
    for _ in range(10):
        try:
            if path.name == LOCK_NAME and path.is_file() and not path.is_symlink():
                path.unlink()
            return
        except OSError:
            time.sleep(0.02)


def _unlink_file(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        if path.is_symlink():
            path.unlink()
            return True
        return False
    path.unlink()
    return True


def _owned_plugin(path: Path) -> bool:
    manifest_path = path / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        return False
    try:
        parsed = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return isinstance(parsed, dict) and parsed.get("id") == PLUGIN_ID


def _remove_tree(path: Path) -> None:
    for child in sorted(path.rglob("*"), reverse=True):
        if child.is_symlink():
            child.unlink()
        elif child.is_file():
            child.unlink()
        elif child.is_dir():
            child.rmdir()
    path.rmdir()


def _agent_names(path: Path | None) -> list[str]:
    if path is None or path.is_symlink() or not path.is_dir():
        return []
    return sorted(item.name for item in path.iterdir() if item.is_file())


def _paths_conflict(
    state_dir: Path,
    plugin_dir: Path | None,
    agents_dir: Path | None,
) -> bool:
    paths = [state_dir]
    if plugin_dir is not None:
        paths.append(plugin_dir)
    if agents_dir is not None:
        paths.append(agents_dir)
    resolved = [path.resolve() for path in paths]
    if len(resolved) != len(set(resolved)):
        return True
    for left in resolved:
        for right in resolved:
            if left == right:
                continue
            if _is_relative_to(left, right) or _is_relative_to(right, left):
                return True
    return False


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


if __name__ == "__main__":
    raise SystemExit(main())
