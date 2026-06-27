#!/usr/bin/env python3
"""Fail when LCOV line coverage is below the requested percent."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check_lcov.py <lcov.info> <minimum_percent>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    minimum = float(sys.argv[2])
    found = 0
    hit = 0

    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("DA:"):
            continue
        _, data = line.split(":", 1)
        _, hits = data.split(",", 1)
        found += 1
        if int(hits) > 0:
            hit += 1

    percent = 100.0 if found == 0 else hit * 100.0 / found
    print(f"line coverage: {percent:.2f}% ({hit}/{found})")
    if percent < minimum:
        print(f"coverage below required {minimum:.2f}%", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
