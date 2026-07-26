#!/usr/bin/env python3
"""Verify a MiSTer.ini keeps the required MiSTerPlex [Plex] video-mode pins."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REFERENCE = ROOT / "assets/MiSTer.ini.Plex.required"


def parse_ini_section(path: Path, section: str) -> dict[str, str]:
    found = False
    active = False
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            active = line[1:-1].strip() == section
            found = found or active
            continue
        if not active or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.split(";", 1)[0].split("#", 1)[0].strip()
    if not found:
        raise ValueError(f"[{section}] section is missing")
    return values


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("ini", type=Path, help="MiSTer.ini to verify")
    ap.add_argument("--reference", type=Path, default=DEFAULT_REFERENCE,
                    help="required [Plex] key/value reference")
    args = ap.parse_args(argv)

    try:
        required = parse_ini_section(args.reference, "Plex")
        actual = parse_ini_section(args.ini, "Plex")
    except Exception as e:
        print(
            f"FAIL: MiSTer.ini [Plex] guard could not parse input: {e}. "
            "Why it matters: missing or commented video_mode pins let MiSTer retune the Plex "
            "core and can scramble the user's display. Restore the checked-in "
            "assets/MiSTer.ini.Plex.required keys in the live [Plex] section.",
            file=sys.stderr,
        )
        return 1

    problems = []
    for key, want in required.items():
        got = actual.get(key)
        if got != want:
            problems.append(f"{key}: expected {want!r}, got {got!r}")

    if problems:
        print("FAIL: MiSTer.ini [Plex] video-mode guard mismatch.", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            "Why it matters: video_mode/video_mode_ntsc/video_mode_pal are deliberate "
            "anti-retune pins for the Plex core. If they are commented out or changed, "
            "MiSTer may choose an unsafe mode and scramble the display. Restore the "
            "reference keys or intentionally update assets/MiSTer.ini.Plex.required "
            "with lab evidence.",
            file=sys.stderr,
        )
        return 1

    print(f"PASS MiSTer.ini [Plex] guard: {args.ini}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
