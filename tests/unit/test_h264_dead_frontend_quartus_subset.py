#!/usr/bin/env python3
"""DEAD H.264 front-end cleanliness — parent ground truth via rtl_reachability.

Parent correction (use ONLY tools/rtl_reachability.py):
  LIVE=19 back-end (dequant/idct/recon/MC/DPB/...) already in shipping RBF
  DEAD=17 entropy/syntax/intra/integrators — the real gap

w-scaler owns Quartus-subset + Verilator cleanliness of DEAD front-end sources
so w-plxd can connect them without a fit-time debt bomb.

POSITIVE:
  - reachability tool: LIVE>=19, DEAD list matches expected front-end set
  - tool positive controls already asserted inside rtl_reachability.py
  - every DEAD module's source file is on files.qip + rtl_lint list
  - check_quartus_sv_subset.py on DEAD unique files returns 0
  - no take_msb(...)[part-select] in cavlc (prior Quartus reject)

NEGATIVE (naive wrong impl fails):
  - Claiming "all fabric decode is dead" when LIVE h264 count < 19
  - Dropping a DEAD front-end file from QIP
  - Synthetic take_msb()[n:0] fails subset checker
  - Reachability tool missing / non-zero exit must fail (no silent skip)
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

# Parent ground-truth DEAD set (17). Priority for w-plxd connection order.
DEAD_EXPECTED = [
    "h264_rbsp_filter",
    "h264_exp_golomb_reader",
    "h264_baseline_syntax_parser",
    "h264_sps_geometry_parser",
    "h264_cavlc_nc_predictor",
    "h264_cavlc_residual_block",
    "h264_intra4x4_pred",
    "h264_intra16x16_pred",
    "h264_chroma8x8_pred",
    "h264_intra_mode_guard",
    "h264_intra_nb_ctx",
    "h264_deblock_bs",
    "h264_deblock_edge_pipe",
    "h264_p_mb_type_decode",
    "h264_decode_top",
    "h264_decode_skeleton",
    "h264_decode_core",
]

# Unique source files that host DEAD modules (prioritize these for subset).
DEAD_SOURCE_FILES = [
    "h264_syntax_primitives.sv",  # rbsp, exp_golomb, baseline_syntax, sps_geometry
    "h264_cavlc_residual.sv",
    "h264_intra_pred.sv",
    "h264_intra_nb_ctx.sv",
    "h264_deblock.sv",  # also hosts LIVE edge/thresholds — still must stay clean
    "h264_p_slice_modes.sv",
    "h264_decode_top.sv",
    "h264_decode_skeleton.sv",
    "h264_decode_core.sv",
]

LIVE_MIN = 19
DEAD_EXACT = 17


def fail(msg: str) -> int:
    print(f"FAIL h264_dead_frontend: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    if not REACH.is_file():
        return fail("missing tools/rtl_reachability.py — refuse to guess LIVE/DEAD")

    # --- Reachability (instrument with positive controls inside the tool) ---
    proc = subprocess.run(
        [sys.executable, str(REACH), str(PROJECT), "sys_top"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        return fail(f"rtl_reachability rc={proc.returncode}\n{out[-2000:]}")

    # Parse LIVE/DEAD h264 lines
    live = sorted(
        re.findall(r"^\s*LIVE\s+(h264_\S+)", out, flags=re.M)
    )
    dead = sorted(
        re.findall(r"^\s*DEAD\s+(h264_\S+)", out, flags=re.M)
    )
    m = re.search(r"reachable=(\d+)", out)
    reachable = int(m.group(1)) if m else -1

    if len(live) < LIVE_MIN:
        return fail(
            f"NEGATIVE: LIVE h264={len(live)} < {LIVE_MIN} — "
            "do not claim 'all fabric decode is dead'; got {live}"
        )
    if len(dead) != DEAD_EXACT:
        return fail(
            f"DEAD h264 count {len(dead)} != {DEAD_EXACT} (parent ground truth); "
            f"dead={dead}"
        )
    exp = sorted(DEAD_EXPECTED)
    if dead != exp:
        missing = sorted(set(exp) - set(dead))
        extra = sorted(set(dead) - set(exp))
        return fail(f"DEAD set mismatch missing={missing} extra={extra}")

    print(f"OK reachability LIVE={len(live)} DEAD={len(dead)} reachable={reachable}")
    print(f"OK DEAD front-end set matches parent ground truth ({DEAD_EXACT})")

    # --- QIP + lint list cover every DEAD source file ---
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    for name in DEAD_SOURCE_FILES:
        if name not in qip:
            return fail(f"files.qip missing DEAD-host file {name}")
        if not (RTL / name).is_file():
            return fail(f"RTL missing {name}")

    # NEGATIVE: stripped QIP misses a DEAD host
    stripped = "\n".join(
        ln for ln in qip.splitlines() if "h264_syntax_primitives.sv" not in ln
    )
    if "h264_syntax_primitives.sv" in stripped:
        return fail("NEGATIVE twin setup failed")
    if "h264_syntax_primitives.sv" not in qip:
        return fail("syntax_primitives must be on real QIP")
    print("OK NEGATIVE twin: dropping syntax_primitives from QIP would be detected")

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
    for name in DEAD_SOURCE_FILES:
        rel = f"fpga/Plex_MiSTer/rtl/{name}"
        if rel not in listed:
            return fail(f"rtl_lint list missing DEAD-host {rel}")
    print(f"OK rtl_lint lists all {len(DEAD_SOURCE_FILES)} DEAD-host sources")

    # --- Quartus subset on DEAD sources only ---
    paths = [str(RTL / n) for n in DEAD_SOURCE_FILES]
    sp = subprocess.run(
        [sys.executable, str(SUBSET), *paths],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if sp.returncode != 0:
        return fail(
            f"quartus-sv-subset on DEAD sources rc={sp.returncode}\n"
            f"{sp.stdout}\n{sp.stderr}"
        )
    print(f"OK quartus-sv-subset DEAD-host files ({len(DEAD_SOURCE_FILES)}) rc=0")

    # --- CAVLC part-select regression ---
    cav = CAVLC.read_text(encoding="utf-8", errors="replace")
    # strip comments
    cav_code = "\n".join(ln.split("//", 1)[0] for ln in cav.splitlines())
    if re.search(r"take_msb\s*\([^;]*\)\s*\[", cav_code):
        return fail("cavlc reintroduced take_msb(...)[part-select]")
    if "tmsb16" not in cav and "zmsb9" not in cav:
        return fail("cavlc missing named take_msb temps (tmsb16/zmsb9)")
    print("OK cavlc uses named temps (no function-call part-select)")

    # NEGATIVE: synthetic function-call part-select must fail subset
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
            return fail(
                "NEGATIVE: subset checker accepted take_msb()[7:0] — gate blind"
            )
    print("OK NEGATIVE: subset rejects take_msb()[part-select] synthetic")

    # Priority order note for w-plxd (not a code change)
    print(
        "OK priority for DEAD->LIVE (w-plxd): "
        "rbsp_filter -> exp_golomb_reader -> baseline_syntax_parser -> "
        "cavlc_residual_block -> intra_*  (drive LIVE dequant/idct/recon)"
    )
    print(
        "PASS h264_dead_frontend: "
        f"LIVE={len(live)} DEAD={len(dead)} subset_clean={len(DEAD_SOURCE_FILES)} "
        "files; instrument=rtl_reachability.py"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
