#!/usr/bin/env python3
"""Regression: body-scoped edges + hard controls for tools/rtl_reachability.py."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "rtl_reachability.py"
RTL = ROOT / "fpga" / "Plex_MiSTer"


def main() -> int:
    if not TOOL.is_file():
        print("FAIL: missing tools/rtl_reachability.py", file=sys.stderr)
        return 2

    # Direct proof of body-slice: pure leaf has 0 children; file-wide has >0.
    sys.path.insert(0, str(TOOL.parent))
    import importlib.util

    spec = importlib.util.spec_from_file_location("rtl_reachability", TOOL)
    rr = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(rr)

    dpb = (RTL / "rtl" / "h264_dpb.sv").read_text(errors="ignore")
    raw = rr.strip_comments(dpb)
    known = set(rr.MODULE_DECL_RE.findall(raw))
    bodies = rr.module_bodies(raw)
    leaf = "h264_dpb_i420_addr"
    file_kids = rr.instantiations(raw, known)
    body_kids = rr.instantiations(bodies[leaf], known)
    if body_kids:
        print(f"FAIL: {leaf} body children should be [] got {body_kids}", file=sys.stderr)
        return 1
    if not file_kids:
        print("FAIL: file-wide kids empty — positive control for the bug is gone", file=sys.stderr)
        return 1
    if leaf not in file_kids and len(file_kids) < 1:
        print("FAIL: expected file-wide false children", file=sys.stderr)
        return 1
    print(f"OK body-slice: {leaf} body=[] file_wide={sorted(file_kids)}")

    proc = subprocess.run(
        [sys.executable, str(TOOL), str(RTL), "sys_top"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    print(proc.stdout, end="")
    if proc.stderr:
        print(proc.stderr, end="", file=sys.stderr)
    if proc.returncode != 0:
        print(f"FAIL: rtl_reachability rc={proc.returncode}", file=sys.stderr)
        return proc.returncode

    if "controls=PASS" not in proc.stdout:
        print("FAIL: controls=PASS not in tool stdout", file=sys.stderr)
        return 1
    if "edges[h264_dpb_i420_addr] (0)" not in proc.stdout:
        print("FAIL: expected empty edges for i420_addr", file=sys.stderr)
        return 1

    # Negative: tool must fail if we break body-slicing (monkey not needed —
    # the body==[] vs file_wide proof above is the permanent control).
    print("OK rtl_reachability controls PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
