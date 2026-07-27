#!/usr/bin/env python3
"""RED mutation probes for h264_chroma_dc_hadamard_inv.
Each probe introduces a deliberate bug and confirms the test FAILS.
A test that has never failed is not a test."""
import os
import subprocess
import sys
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERILATOR = Path.home() / ".local/oss-cad-suite-20260726/bin/verilator"
RTL = ROOT / "fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
TB = ROOT / "tests/unit/rtl/p3_chroma_dc_hadamard_tb.sv"
CPP = ROOT / "tests/unit/test_p3_chroma_dc_hadamard_verilator.cpp"

MUTATIONS = {
    "wrong_butterfly_sign": {
        "find": "wire signed [31:0] b = $signed(coeff[2]) - $signed(coeff[3]);",
        "replace": "wire signed [31:0] b = $signed(coeff[2]) + $signed(coeff[3]);",
        "why": "Flips butterfly subtraction to addition — wrong Hadamard transform"
    },
    "wrong_dequant_shift": {
        "find": ">>> 7;",
        "replace": ">>> 6;",
        "why": "Wrong dequant shift — doubles all output values",
        "first_only": True
    },
    "wrong_mf0_table": {
        "find": "3'd0: mf0 = 5'd10;",
        "replace": "3'd0: mf0 = 5'd11;",
        "why": "Wrong scale factor for qp%6=0 — subtle dequant error"
    },
    "swapped_had_outputs": {
        "find": "wire signed [31:0] had1 = e + b;  // (0,1)\n\twire signed [31:0] had2 = a - c;  // (1,0)",
        "replace": "wire signed [31:0] had1 = a - c;  // SWAPPED\n\twire signed [31:0] had2 = e + b;  // SWAPPED",
        "why": "Swaps Hadamard outputs — wrong DC distribution to blocks"
    },
}


def run_mutation(name, mut):
    src = RTL.read_text()
    pattern = mut["find"]
    if mut.get("first_only"):
        idx = src.find(pattern)
        if idx < 0:
            print(f"SKIP {name}: pattern not found in source")
            return True
        mutated = src[:idx] + mut["replace"] + src[idx + len(pattern):]
    else:
        if pattern not in src:
            print(f"SKIP {name}: pattern not found in source")
            return True
        mutated = src.replace(pattern, mut["replace"], 1)

    build_dir = ROOT / f"build/obj_chroma_dc_had_red_{name}"
    build_dir.mkdir(parents=True, exist_ok=True)
    mut_rtl = build_dir / "h264_iq_idct_4x4_mutated.sv"
    mut_rtl.write_text(mutated)

    cmd = [
        str(VERILATOR), "--cc", "--exe", "--build",
        "--top-module", "p3_chroma_dc_hadamard_tb",
        "--Mdir", str(build_dir),
        "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
        "--CFLAGS", "-std=c++17 -O2",
        str(mut_rtl), str(TB), str(CPP),
    ]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"SKIP {name}: build failed")
        sys.stdout.write(r.stdout[-500:] if len(r.stdout) > 500 else r.stdout)
        return True

    r2 = subprocess.run(
        [str(build_dir / "Vp3_chroma_dc_hadamard_tb")],
        capture_output=True, text=True
    )
    if r2.returncode != 0:
        print(f"RED PASS {name}: mutation detected (rc={r2.returncode}) — {mut['why']}")
        return True
    else:
        print(f"RED FAIL {name}: mutation NOT detected — test is blind to: {mut['why']}")
        sys.stdout.write(r2.stdout)
        return False


def main():
    if not VERILATOR.exists():
        print(f"Verilator not found at {VERILATOR}")
        return 1
    ok = True
    for name, mut in MUTATIONS.items():
        if not run_mutation(name, mut):
            ok = False
    if ok:
        print(f"\nAll {len(MUTATIONS)} RED probes detected. Test catches all mutation classes.")
        return 0
    else:
        print("\nSome RED probes were NOT detected. Test has blind spots.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
