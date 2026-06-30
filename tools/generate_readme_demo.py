#!/usr/bin/env python3
"""Generate README demo screenshots and the animated GIF from app demo mode."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover - exercised by users without Pillow
    raise SystemExit(
        "Pillow is required to build docs/quotabot-demo.gif. "
        "Install it with: python -m pip install pillow"
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "app"
DOCS_DIR = ROOT / "docs"

STATIC_SHOTS = (
    "screenshot-widget.png",
    "screenshot-analytics.png",
    "screenshot-top.png",
)

GIF_FRAMES = (
    "demo-01-widget-expanded.png",
    "demo-02-widget-collapsed.png",
    "demo-03-widget-expanded.png",
    "demo-04-analytics-90d.png",
    "demo-05-top.png",
)


def _run(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def _tool(name: str) -> str:
    path = shutil.which(name) or shutil.which(f"{name}.bat")
    if path is None:
        raise SystemExit(f"{name} not found on PATH")
    return path


def _flutter_target() -> tuple[str, Path]:
    system = platform.system().lower()
    if system == "windows":
        return "windows", APP_DIR / "build/windows/x64/runner/Debug/quotabot.exe"
    if system == "darwin":
        return (
            "macos",
            APP_DIR / "build/macos/Build/Products/Debug/quotabot.app/Contents/MacOS/quotabot",
        )
    if system == "linux":
        machine = platform.machine().lower()
        arch = "arm64" if machine in {"arm64", "aarch64"} else "x64"
        return "linux", APP_DIR / f"build/linux/{arch}/debug/bundle/quotabot"
    raise SystemExit(f"Unsupported platform for Flutter desktop capture: {system}")


def _capture(frame_dir: Path) -> None:
    target, executable = _flutter_target()
    _run([_tool("flutter"), "build", target, "--debug"], APP_DIR)
    if not executable.exists():
        raise SystemExit(f"Flutter build did not produce {executable}")
    env = os.environ.copy()
    env["QUOTABOT_SHOTS"] = "1"
    env["QUOTABOT_GIF_FRAMES"] = "1"
    env["QUOTABOT_SHOTS_DIR"] = str(frame_dir)
    _run([str(executable)], ROOT, env=env)


def _copy_static_shots(frame_dir: Path) -> None:
    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    for name in STATIC_SHOTS:
        src = frame_dir / name
        if not src.exists():
            raise SystemExit(f"Missing captured screenshot: {src}")
        shutil.copyfile(src, DOCS_DIR / name)


def _fit_on_canvas(path: Path, canvas: tuple[int, int]) -> Image.Image:
    source = Image.open(path).convert("RGBA")
    max_w, max_h = canvas
    scale = min(max_w / source.width, max_h / source.height, 1.0)
    size = (max(1, round(source.width * scale)), max(1, round(source.height * scale)))
    resized = source.resize(size, Image.Resampling.LANCZOS)
    frame = Image.new("RGBA", canvas, (12, 14, 18, 255))
    offset = ((max_w - size[0]) // 2, (max_h - size[1]) // 2)
    frame.alpha_composite(resized, offset)
    return frame


def _assemble_gif(frame_dir: Path) -> None:
    for name in GIF_FRAMES:
        if not (frame_dir / name).exists():
            raise SystemExit(f"Missing GIF frame: {frame_dir / name}")

    frames = [_fit_on_canvas(frame_dir / name, (680, 760)) for name in GIF_FRAMES]
    paletted = [frame.convert("P", palette=Image.Palette.ADAPTIVE) for frame in frames]
    out = DOCS_DIR / "quotabot-demo.gif"
    paletted[0].save(
        out,
        save_all=True,
        append_images=paletted[1:],
        duration=[1000, 650, 900, 1300, 1300],
        loop=0,
        optimize=True,
    )
    print(f"Wrote {out}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--skip-capture",
        action="store_true",
        help="Use existing docs screenshots and frame files in --frames-dir.",
    )
    parser.add_argument(
        "--frames-dir",
        type=Path,
        help="Directory for intermediate PNG frames. Defaults to a temp dir.",
    )
    args = parser.parse_args()

    if args.frames_dir:
        frame_dir = args.frames_dir.resolve()
        frame_dir.mkdir(parents=True, exist_ok=True)
        cleanup = None
    else:
        cleanup = tempfile.TemporaryDirectory(prefix="quotabot-readme-demo-")
        frame_dir = Path(cleanup.name)

    try:
        if args.skip_capture:
            for name in STATIC_SHOTS:
                src = DOCS_DIR / name
                if src.exists():
                    shutil.copyfile(src, frame_dir / name)
        else:
            _capture(frame_dir)
        _copy_static_shots(frame_dir)
        _assemble_gif(frame_dir)
    finally:
        if cleanup is not None:
            cleanup.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
