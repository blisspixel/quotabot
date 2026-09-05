"""Render five static README views from the real Flutter widgets and demo data."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", type=Path, required=True)
    parser.add_argument("--fonts", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "docs" / "gallery")
    args = parser.parse_args()
    flutter = args.flutter.resolve(strict=True)
    fonts = args.fonts.resolve(strict=True)
    for font in ("segoeui.ttf", "segoeuib.ttf", "consola.ttf", "consolab.ttf"):
        if not (fonts / font).is_file():
            parser.error(f"Missing font: {font}")
    icons = flutter.parent / "cache/artifacts/material_fonts/materialicons-regular.otf"
    if not icons.is_file():
        parser.error("The supplied Flutter SDK has no cached Material Icons font.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for name in (
        "QUOTABOT_SHOT",
        "QUOTABOT_SHOTS",
        "QUOTABOT_GIF_FRAMES",
        "QUOTABOT_DEMO",
    ):
        env.pop(name, None)
    env["QUOTABOT_GALLERY_OUTPUT"] = str(output)
    env["QUOTABOT_GALLERY_FONTS"] = str(fonts)
    env["QUOTABOT_GALLERY_ICON_FONT"] = str(icons)
    command = [
        str(flutter),
        "test",
        "--no-pub",
        "test/support/capture_readme_gallery.dart",
    ]
    if os.name == "nt" and flutter.suffix.lower() in {".bat", ".cmd"}:
        powershell = shutil.which("pwsh")
        if powershell is None:
            parser.error("PowerShell 7 is required for the Windows Flutter wrapper.")
        quoted = " ".join("'" + item.replace("'", "''") + "'" for item in command)
        command = [
            powershell,
            "-NoProfile",
            "-Command",
            "& " + quoted + "; exit $LASTEXITCODE",
        ]
    subprocess.run(command, cwd=ROOT / "app", env=env, check=True, timeout=180)
    for name in ("quota", "analytics", "local-models", "terminal", "mini"):
        path = output / f"{name}.png"
        if not path.is_file():
            raise SystemExit(f"Capture did not produce {path.name}.")
        print(path)


if __name__ == "__main__":
    main()
