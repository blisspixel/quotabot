"""Dev helper: renders an ANSI text frame (.ans) to a PNG for visual QA.

Understands exactly the SGR subset quotabot's renderer emits: reset (0),
bold (1), dim (2), named foregrounds 31/32/33/36, 256-color 38;5;N, and
truecolor 38;2;R;G;B. Draws with a monospace font on a dark canvas that
matches the README demo background, so a QA reviewer sees what a dark
terminal would show.

Usage: python tools/ansi_to_png.py <in.ans|dir> [out.png|dir]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BG = (12, 14, 18)
FG = (208, 212, 220)
DIM_FACTOR = 0.55
NAMED = {
    31: (220, 80, 80),
    32: (92, 200, 108),
    33: (210, 170, 60),
    36: (86, 182, 194),
}
ANSI256 = {208: (255, 135, 0)}
SGR = re.compile(r"\x1b\[([0-9;]*)m")

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\CascadiaMono.ttf",
    r"C:\Windows\Fonts\consola.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]
BOLD_CANDIDATES = [
    r"C:\Windows\Fonts\CascadiaMono.ttf",  # weight via stroke below
    r"C:\Windows\Fonts\consolab.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
]
SIZE = 18


def load_font(candidates: list[str]) -> ImageFont.FreeTypeFont:
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, SIZE)
    raise SystemExit("no monospace font found; add one to FONT_CANDIDATES")


def parse_line(line: str):
    """Yields (char, fg, bold, dim) for each visible character."""
    fg, bold, dim = None, False, False
    i = 0
    while i < len(line):
        m = SGR.match(line, i)
        if m:
            params = [int(p) for p in m.group(1).split(";") if p] or [0]
            j = 0
            while j < len(params):
                p = params[j]
                if p == 0:
                    fg, bold, dim = None, False, False
                elif p == 1:
                    bold = True
                elif p == 2:
                    dim = True
                elif p in NAMED:
                    fg = NAMED[p]
                elif p == 38 and j + 2 < len(params) and params[j + 1] == 5:
                    fg = ANSI256.get(params[j + 2], FG)
                    j += 2
                elif p == 38 and j + 4 < len(params) and params[j + 1] == 2:
                    fg = tuple(params[j + 2 : j + 5])
                    j += 4
                j += 1
            i = m.end()
            continue
        yield line[i], fg, bold, dim
        i += 1


def render(src: Path, dst: Path, font, bold_font) -> None:
    lines = src.read_text(encoding="utf-8").splitlines()
    probe = Image.new("RGB", (8, 8))
    d = ImageDraw.Draw(probe)
    box = d.textbbox((0, 0), "M", font=font)
    cw, ch = int(box[2] - box[0]), SIZE + 6
    cols = max((sum(1 for _ in parse_line(line)) for line in lines), default=80)
    pad = 16
    img = Image.new("RGB", (cols * cw + 2 * pad, len(lines) * ch + 2 * pad), BG)
    draw = ImageDraw.Draw(img)
    for row, line in enumerate(lines):
        col = 0
        for char, fg, bold, dim in parse_line(line):
            color = fg or FG
            if dim:
                color = tuple(int(c * DIM_FACTOR) for c in color)
            x, y = pad + col * cw, pad + row * ch
            f = bold_font if bold else font
            draw.text(
                (x, y),
                char,
                font=f,
                fill=color,
                stroke_width=1 if bold else 0,
                stroke_fill=color if bold else None,
            )
            col += 1
    img.save(dst)
    print(f"wrote {dst} ({img.width}x{img.height})")


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = Path(sys.argv[1])
    font = load_font(FONT_CANDIDATES)
    bold_font = load_font(BOLD_CANDIDATES)
    if src.is_dir():
        out = Path(sys.argv[2]) if len(sys.argv) > 2 else src
        out.mkdir(parents=True, exist_ok=True)
        for f in sorted(src.glob("*.ans")):
            render(f, out / f.with_suffix(".png").name, font, bold_font)
    else:
        dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".png")
        render(src, dst, font, bold_font)


if __name__ == "__main__":
    main()
