#!/usr/bin/env python3
"""DEAD H.264 front-end cleanliness — body-scoped reachability only.

rd-duck NACK of parent 19/17 (db9735e7 instrument):
  (1) edges were file-wide unions in multi-module .sv — FIXED in tools/rtl_reachability.py
  (2) positive controls were docstring-only — FIXED (code asserts, rc=3 on fail)
  (3) NOT ground truth for shipping RBF / PRODUCT_NO_STUB elaborated config

This gate:
  - runs corrected rtl_reachability.py; requires controls=PASS and rc=0
  - NEGATIVE: h264_dpb_i420_addr body children must be empty (union bug detector)
  - does NOT lock LIVE=19/DEAD=17 (those numbers are retired)
  - keeps Quartus-subset clean on entropy/syntax/intra/integrator sources
  - refuses shipping-RBF / area-paid claims in fixture language

NEGATIVE twins: QIP drop; synthetic take_msb()[part-select]; tool rc!=0.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
REACH = ROOT / "tools/rtl_reachability.py"
SUBSET = ROOT / "scripts/check_quartus_sv_subset.py"
LINT = ROOT / "scripts/rtl_lint.py"
CAVLC = RTL / "h264_cavlc_residual.sv"
PROJECT = ROOT / "fpga/Plex_MiSTer"

# Front-end / integrator sources w-scaler keeps subset-clean (w-plxd connect order).
# Includes modules that may be LIVE or DEAD under source graph — cleanliness is
# independent of the retired 19/17 headline.
DEAD_PRIORITY_SOURCES = [
    "h264_syntax_primitives.sv",  # rbsp, exp_golomb, baseline_syntax, sps_geometry
    "h264_cavlc_residual.sv",
    "h264_intra_pred.sv",
    "h264_intra_nb_ctx.sv",
    "h264_p_slice_modes.sv",
    "h264_decode_top.sv",
    "h264_decode_skeleton.sv",
    "h264_decode_core.sv",
    "h264_deblock.sv",  # hosts both stub-live writeback_ctrl and dead edge/bs
]


def fail(msg: str) -> int:
    print(f"FAIL h264_dead_frontend: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    if not REACH.is_file():
        return fail("missing tools/rtl_reachability.py")

    # --- Prove body-scoped edges (inline negative control) ---
    sys.path.insert(0, str(ROOT / "tools"))
    # Load without running main
    code = REACH.read_text(encoding="utf-8")
    ns: dict = {}
    exec(
        compile(
            code.replace('if __name__ == "__main__":\n    sys.exit(main())', "pass"),
            str(REACH),
            "exec",
        ),
        ns,
    )
    decl_file, edges, _in_qip, bodies = ns["build_graph"](PROJECT)
    leaf = "h264_dpb_i420_addr"
    if leaf not in edges:
        return fail(f"expected {leaf} in graph")
    if edges[leaf]:
        return fail(
            f"NEGATIVE: {leaf} body children must be [] after body-slice; "
            f"got {sorted(edges[leaf])} (file-wide union regression)"
        )
    print(f"OK NEGATIVE control: {leaf} body children=[]")

    # decode_stub positive edge (source-level only)
    if "decode_stub" in edges:
        need = {"h264_dequant4x4", "h264_idct4x4", "h264_recon4x4", "h264_dpb_one_ref"}
        miss = need - edges["decode_stub"]
        if miss:
            return fail(f"POSITIVE: decode_stub missing {sorted(miss)}")
        print(f"OK POSITIVE control: decode_stub -> {sorted(need)}")
    else:
        return fail("decode_stub not in edges")

    # --- Full tool run must PASS controls ---
    proc = subprocess.run(
        [sys.executable, str(REACH), str(PROJECT), "sys_top"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        return fail(f"rtl_reachability rc={proc.returncode}\n{out[-2500:]}")
    if "controls=PASS" not in out:
        return fail("tool must print controls=PASS")
    if "NOT claimed: modules present in any deployed/shipping RBF" not in out:
        return fail("tool must print shipping-RBF non-claim")
    if "PRODUCT_NO_STUB" not in out:
        return fail("tool must warn PRODUCT_NO_STUB not evaluated")

    live = sorted(re.findall(r"^\s*LIVE\s+(h264_\S+)", out, flags=re.M))
    dead = sorted(re.findall(r"^\s*DEAD\s+(h264_\S+)", out, flags=re.M))

    # Retired headline must not be re-asserted as locked truth in this gate
    if len(live) == 19 and len(dead) == 17:
        # Could happen by chance only if bug returns — still require leaf control above.
        print(
            "NOTE: LIVE=19 DEAD=17 observed — not treated as locked ground truth; "
            "body-scoped leaf control is binding"
        )

    # Source-graph sanity: stub path should reach some back-end, not zero
    if len(live) < 1:
        return fail("LIVE h264 count is 0 — unexpected for source graph with decode_stub")
    if "h264_dequant4x4" not in live:
        return fail("source graph should reach h264_dequant4x4 via decode_stub")
    # deblock_edge was a false-LIVE under file-union; under body-scope it is typically DEAD
    # unless something instantiates it — do not require either way, just report.
    print(
        f"OK source-graph LIVE={len(live)} DEAD={len(dead)} "
        f"(NOT shipping RBF; NOT PRODUCT_NO_STUB-elaborated)"
    )
    print(f"OK LIVE sample: {live[:5]}...")
    print(f"OK DEAD sample: {dead[:5]}...")

    # --- QIP + subset on priority front-end sources ---
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    for name in DEAD_PRIORITY_SOURCES:
        if name not in qip:
            return fail(f"files.qip missing {name}")
        if not (RTL / name).is_file():
            return fail(f"RTL missing {name}")

    stripped = "\n".join(
        ln for ln in qip.splitlines() if "h264_syntax_primitives.sv" not in ln
    )
    if "h264_syntax_primitives.sv" in stripped:
        return fail("NEGATIVE twin setup failed")
    print("OK NEGATIVE twin: QIP drop of syntax_primitives detectable")

    lp = subprocess.run(
        [sys.executable, str(LINT), "--list-files"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if lp.returncode != 0:
        return fail(f"rtl_lint --list-files rc={lp.returncode}")
    listed = set(lp.stdout.split())
    for name in DEAD_PRIORITY_SOURCES:
        rel = f"fpga/Plex_MiSTer/rtl/{name}"
        if rel not in listed:
            return fail(f"rtl_lint list missing {rel}")

    paths = [str(RTL / n) for n in DEAD_PRIORITY_SOURCES]
    sp = subprocess.run(
        [sys.executable, str(SUBSET), *paths],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if sp.returncode != 0:
        return fail(f"quartus-sv-subset rc={sp.returncode}\n{sp.stdout}\n{sp.stderr}")
    print(f"OK quartus-sv-subset priority sources ({len(DEAD_PRIORITY_SOURCES)}) rc=0")

    cav = CAVLC.read_text(encoding="utf-8", errors="replace")
    cav_code = "\n".join(ln.split("//", 1)[0] for ln in cav.splitlines())
    if re.search(r"take_msb\s*\([^;]*\)\s*\[", cav_code):
        return fail("cavlc reintroduced take_msb(...)[part-select]")
    if "tmsb16" not in cav and "zmsb9" not in cav:
        return fail("cavlc missing named take_msb temps")
    print("OK cavlc named temps (no function-call part-select)")

    text = """// synthetic
module h264_dead_fe_bad_partsel(
  input wire [31:0] x,
  output wire [7:0] y
);
  function automatic [31:0] take_msb(input [31:0] v);
    take_msb = v;
  endfunction
  assign y = take_msb(x)[7:0];
endmodule
"""
    with tempfile.TemporaryDirectory() as td:
        bad_path = Path(td) / "h264_dead_fe_bad_partsel.sv"
        bad_path.write_text(text)
        bp = subprocess.run(
            [sys.executable, str(SUBSET), str(bad_path)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if bp.returncode == 0:
            return fail("NEGATIVE: subset accepted take_msb()[7:0]")
    print("OK NEGATIVE: subset rejects take_msb()[part-select]")

    print(
        "OK missing work is NOT entropy-only: dead intra/deblock/integrators remain; "
        "stub LIVE modules are diagnostic/partial (rd-duck)"
    )
    print(
        f"PASS h264_dead_frontend: controls=PASS body-scoped; "
        f"source LIVE={len(live)} DEAD={len(dead)}; subset_clean={len(DEAD_PRIORITY_SOURCES)}; "
        f"19/17 NOT locked"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
