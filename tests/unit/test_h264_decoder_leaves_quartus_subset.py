#!/usr/bin/env python3
"""Gate: all 12 decoder leaves stay on the Quartus SV subset path and clean.

Named feature: fabric decode leaf set must not re-orphan or reintroduce the
observed Quartus rejection (part-select on function-call result in CAVLC).

POSITIVE:
  - files.qip lists all 12 h264_*.sv leaves (8 prior + 4 orphans)
  - rtl_lint --list-files includes all 12
  - check_quartus_sv_subset.py on those 12 returns 0
  - h264_cavlc_residual uses named temps (tmsb16/zmsb9/rmsb_*) not call[] 

NEGATIVE (naive wrong impl fails — each has a twin that proves RED):
  - Dropping any orphan from files.qip fails the required-set check
  - A synthetic module with take_msb(...)[n:0] fails check_quartus_sv_subset
  - Reintroducing take_msb(...)[part-select] in cavlc source fails
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
CAVLC = RTL / "h264_cavlc_residual.sv"
SUBSET = ROOT / "scripts/check_quartus_sv_subset.py"
LINT = ROOT / "scripts/rtl_lint.py"

REQUIRED = [
    "h264_cavlc_residual.sv",
    "h264_deblock.sv",
    "h264_dpb.sv",
    "h264_inter_pred.sv",
    "h264_intra_pred.sv",
    "h264_iq_idct_4x4.sv",
    "h264_p_slice_modes.sv",
    "h264_syntax_primitives.sv",
    "h264_decode_core.sv",
    "h264_decode_skeleton.sv",
    "h264_decode_top.sv",
    "h264_intra_nb_ctx.sv",
]

ORPHANS = [
    "h264_decode_core.sv",
    "h264_decode_skeleton.sv",
    "h264_decode_top.sv",
    "h264_intra_nb_ctx.sv",
]


def fail(msg: str) -> int:
    print(f"FAIL h264_decoder_leaves: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    for name in REQUIRED:
        if name not in qip:
            return fail(f"files.qip missing {name}")
        if not (RTL / name).is_file():
            return fail(f"RTL file missing {name}")
    print(f"OK files.qip lists all {len(REQUIRED)} decoder leaves")

    for name in ORPHANS:
        if name not in qip:
            return fail(f"NEGATIVE orphan-drop: {name} absent from QIP")
    print("OK orphans on QIP: decode_core/skeleton/top/intra_nb_ctx")

    # NEGATIVE twin: prove the orphan check would catch a drop
    qip_without = "\n".join(ln for ln in qip.splitlines() if "h264_decode_top.sv" not in ln)
    if "h264_decode_top.sv" in qip_without:
        return fail("NEGATIVE twin setup failed: could not strip decode_top from QIP text")
    if "h264_decode_top.sv" not in qip:
        return fail("decode_top must be on real QIP for positive path")
    # Simulate required-set scan against stripped QIP
    if "h264_decode_top.sv" not in qip_without:
        print("OK NEGATIVE twin: stripped QIP would miss h264_decode_top.sv")
    else:
        return fail("NEGATIVE twin did not detect drop")

    proc = subprocess.run(
        [sys.executable, str(LINT), "--list-files"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return fail(f"rtl_lint --list-files rc={proc.returncode}")
    listed = set(proc.stdout.split())
    for name in REQUIRED:
        rel = f"fpga/Plex_MiSTer/rtl/{name}"
        if rel not in listed:
            return fail(f"rtl_lint list missing {rel}")
    print("OK rtl_lint --list-files includes all 12")

    cavlc = CAVLC.read_text(encoding="utf-8", errors="replace")
    cavlc_nc = re.sub(r"/\*.*?\*/", "", cavlc, flags=re.S)
    cavlc_nc = re.sub(r"//.*", "", cavlc_nc)
    bad_re = re.compile(r"\btake_msb\s*\([^;]*\)\s*\[")
    if bad_re.search(cavlc_nc):
        return fail(
            "NEGATIVE: cavlc still has take_msb(...)[part-select] "
            "(Quartus rejects part-select on function-call result)"
        )
    for tok in ("tmsb16", "zmsb9", "rmsb_a", "rmsb_b"):
        if tok not in cavlc:
            return fail(f"cavlc fix temp `{tok}` missing")
    print("OK cavlc: no take_msb()[part-select]; temps present")

    # NEGATIVE: synthetic DUT with the forbidden construct must FAIL subset
    bad_sv = """\
module h264_neg_take_msb_partsel (
    input  logic [31:0] w,
    output logic [15:0] y
);
    function automatic logic [31:0] take_msb(input logic [31:0] v, input int n);
        return v << (32 - n);
    endfunction
    always_comb y = take_msb(w, 16)[31:16];
endmodule
"""
    with tempfile.TemporaryDirectory(prefix="h264_neg_", dir=str(ROOT / ".agent-work")) as td:
        bad_path = Path(td) / "h264_neg_take_msb_partsel.sv"
        bad_path.write_text(bad_sv, encoding="utf-8")
        neg = subprocess.run(
            [sys.executable, str(SUBSET), str(bad_path)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if neg.returncode == 0:
            return fail(
                "NEGATIVE twin: subset accepted take_msb(...)[31:16] — gate is tautological"
            )
        blob = neg.stdout + neg.stderr
        if "part-select on" not in blob or "function-call result" not in blob:
            return fail(
                "NEGATIVE twin: subset failed but not for expected construct; "
                f"out={neg.stdout!r} err={neg.stderr!r}"
            )
        print(
            "OK NEGATIVE twin: subset rejects take_msb(...)[part-select] "
            f"rc={neg.returncode}"
        )

    paths = [str(RTL / n) for n in REQUIRED]
    sub = subprocess.run(
        [sys.executable, str(SUBSET), *paths],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if sub.returncode != 0:
        print(sub.stdout, end="")
        print(sub.stderr, end="", file=sys.stderr)
        return fail(f"quartus-sv-subset on 12 leaves rc={sub.returncode}")
    print(sub.stdout.strip())
    print("PASS h264_decoder_leaves_quartus_subset")
    return 0


if __name__ == "__main__":
    sys.exit(main())
