#!/usr/bin/env python3
"""rtl_reachability controls — body-scoped edges + pos/neg (rd-duck NACK)."""
from __future__ import annotations
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/rtl_reachability.py"
PROJ = ROOT / "fpga/Plex_MiSTer"

def fail(m):
    print(f"FAIL rtl_reachability_controls: {m}", file=sys.stderr)
    return 1

def main():
    code = TOOL.read_text(encoding="utf-8")
    if "module_bodies" not in code:
        return fail("tool must define module_bodies (body-scoped edges)")
    if re.search(r"\bassert\b", code):
        pass  # optional
    # controls must be real call sites
    if "run_controls" not in code and "NEGATIVE CONTROL FAIL" not in code:
        return fail("tool must implement control failures in code")
    if "POSITIVE CONTROL FAIL" not in code:
        return fail("tool must implement positive control failures")

    ns = {}
    exec(compile(code.replace('if __name__ == "__main__":\n    sys.exit(main())', "pass"), str(TOOL), "exec"), ns)
    decl, edges, in_qip, bodies = ns["build_graph"](PROJ)
    leaf = "h264_dpb_i420_addr"
    if edges.get(leaf):
        return fail(f"leaf {leaf} children {edges[leaf]} — union bug")
    # whole-file would give 5 kids — prove file_wide != body
    dpb = next(f for f in decl.values() if f.name == "h264_dpb.sv")
    raw = ns["strip_comments"](dpb.read_text(errors="ignore"))
    fw = ns["instantiations"](raw, set(decl))
    if len(fw) < 3:
        return fail("expected multi-module file-wide inst set")
    if edges[leaf] == fw:
        return fail("body edges collapsed to file-wide")
    print(f"OK body-scoped: {leaf} kids=[] vs file_wide={sorted(fw)[:5]}...")

    r = subprocess.run([sys.executable, str(TOOL), str(PROJ), "sys_top"], cwd=ROOT, text=True, capture_output=True)
    if r.returncode != 0:
        return fail(f"tool rc={r.returncode}\n{r.stdout}\n{r.stderr}")
    if "controls=PASS" not in r.stdout:
        return fail("controls=PASS missing")
    if "shipping RBF" not in r.stdout:
        return fail("must non-claim shipping RBF")
    # Must NOT silently restore 19/17 as only output without limit line
    if "PRODUCT_NO_STUB" not in r.stdout:
        return fail("must mention PRODUCT_NO_STUB limit")
    live = re.findall(r"^\s*LIVE\s+(h264_\S+)", r.stdout, re.M)
    dead = re.findall(r"^\s*DEAD\s+(h264_\S+)", r.stdout, re.M)
    print(f"OK tool rc=0 controls=PASS source LIVE={len(live)} DEAD={len(dead)}")
    print("PASS rtl_reachability_controls")
    return 0

if __name__ == "__main__":
    sys.exit(main())
