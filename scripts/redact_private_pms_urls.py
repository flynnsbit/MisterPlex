#!/usr/bin/env python3
"""Redact private-range PMS URLs in files before they are committed as evidence.

Does not touch MISTER_HOST (192.168.1.183) and does not weaken
tests/unit/test_no_private_data.sh — that test remains the hard gate on
tracked files. This helper is the cheap default for evidence writers so lab
IPs never land in docs/evidence/.

Usage:
  scripts/redact_private_pms_urls.py PATH [PATH ...]
  scripts/redact_private_pms_urls.py --check PATH   # rc=1 if dirty (for hooks)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Same ranges as test_no_private_data.sh private PMS detector.
PMS_HOSTPORT = re.compile(
    r"(?P<pre>https?://)?"
    r"(?P<ip>(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2[0-9]|3[01])\.\d+\.\d+))"
    r":32400"
)
PLACEHOLDER = "YOUR-PLEX-SERVER"
# Documented MiSTer default — leave alone even if someone put :32400 on it.
MISTER_DEFAULT = "192.168.1.183"


def redact_text(text: str) -> tuple[str, int]:
    n = 0

    def repl(m: re.Match[str]) -> str:
        nonlocal n
        if m.group("ip") == MISTER_DEFAULT:
            return m.group(0)
        n += 1
        pre = m.group("pre") or ""
        return f"{pre}{PLACEHOLDER}:32400"

    return PMS_HOSTPORT.sub(repl, text), n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument("--check", action="store_true", help="report only; rc=1 if any hit")
    args = ap.parse_args()
    dirty = 0
    total = 0
    for path in args.paths:
        if not path.is_file():
            print(f"skip missing {path}", file=sys.stderr)
            continue
        raw = path.read_text(encoding="utf-8", errors="replace")
        out, n = redact_text(raw)
        total += n
        if n == 0:
            continue
        dirty += 1
        if args.check:
            print(f"DIRTY {path} hits={n}")
        else:
            if "PRIVACY_REDACTION" not in out:
                note = (
                    "\n\n# PRIVACY_REDACTION: private-range PMS host:32400 replaced with "
                    f"{PLACEHOLDER}:32400 by scripts/redact_private_pms_urls.py. "
                    "Measurement payload preserved.\n"
                )
                out = out.rstrip() + note
            path.write_text(out, encoding="utf-8")
            print(f"REDACTED {path} hits={n}")
    if args.check:
        print(f"check_hits={total} dirty_files={dirty}")
        return 1 if total else 0
    print(f"redacted_hits={total} files={dirty}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
