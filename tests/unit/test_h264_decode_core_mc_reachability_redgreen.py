#!/usr/bin/env python3
"""Red/green proof that inter-prediction RTL is reachable from h264_decode_core.

A green reachability gate on its own is not evidence: three MiSTerPlex
subsystems have shipped fully disconnected from the product while every unit
test passed.  This gate mutates the *product* instantiation of each inter/DPB
module in turn and requires the core-rooted reachability checker to go RED,
then restores the source and requires it to go GREEN again.

Every mutation edits the instantiation site only (never the module
declaration), so a RED result proves the green result was carried by that
specific product edge and not by the retired decode_stub painter.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
CHECKER = ROOT / "scripts" / "check_rtl_module_instantiations.py"

REQUIRED = [
    "h264_deblock_writeback_ctrl",
    "h264_inter_mc_part",
    "h264_inter_mc_16x16",
    "h264_dpb_one_ref",
    "h264_luma_qpel_block_16x16",
    "h264_chroma_epel_block_8x8",
    "h264_luma_ref_tap_addr",
    "h264_ref_clamp",
]

# module -> list of (file, exact instantiation text) that must be cut to make
# the module unreachable from h264_decode_core.
MUTATIONS: dict[str, list[tuple[str, str]]] = {
    "h264_inter_mc_part": [
        ("h264_decode_core.sv", "h264_inter_mc_part u_product_p16_mc ("),
    ],
    "h264_dpb_one_ref": [
        ("h264_decode_core.sv", "h264_dpb_one_ref #("),
    ],
    "h264_inter_mc_16x16": [
        ("h264_dpb.sv", "h264_inter_mc_16x16 u_full ("),
    ],
    "h264_luma_qpel_block_16x16": [
        ("h264_dpb.sv", "h264_luma_qpel_block_16x16 u_luma ("),
    ],
    "h264_chroma_epel_block_8x8": [
        ("h264_dpb.sv", "h264_chroma_epel_block_8x8 u_chroma_u ("),
        ("h264_dpb.sv", "h264_chroma_epel_block_8x8 u_chroma_v ("),
    ],
    "h264_luma_ref_tap_addr": [
        ("h264_dpb.sv", "h264_luma_ref_tap_addr #(.TAP_COLS(21), .TAP_ORIGIN(2)) u_luma_win_addr ("),
        ("h264_dpb.sv", "h264_luma_ref_tap_addr #(.TAP_COLS(9), .TAP_ORIGIN(0)) u_chroma_win_addr ("),
    ],
    "h264_ref_clamp": [
        ("h264_inter_pred.sv", "h264_ref_clamp u_clamp ("),
    ],
    "h264_deblock_writeback_ctrl": [
        ("h264_decode_core.sv", "h264_deblock_writeback_ctrl #("),
    ],
}

MUTANT_SUFFIX = "_redgreen_mutant"


def run_gate() -> tuple[int, str]:
    cmd = [sys.executable, str(CHECKER), "--root", "h264_decode_core"]
    for mod in REQUIRED:
        cmd += ["--require", mod]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    print(
        "Scope: red/green reachability proof for "
        f"{len(REQUIRED)} required RTL modules rooted at h264_decode_core "
        f"({sum(len(v) for v in MUTATIONS.values())} product instantiation sites mutated)",
        flush=True,
    )

    originals = {name: (RTL / name).read_text() for name in {f for sites in MUTATIONS.values() for f, _ in sites}}

    green_rc, green_out = run_gate()
    if green_rc != 0:
        sys.stderr.write(
            "FAIL h264_decode_core MC reachability red/green: baseline gate is not green\n" + green_out
        )
        return 1
    for mod in REQUIRED:
        if f"REQUIRED_RTL_MODULE_REACHABLE {mod} root=h264_decode_core" not in green_out:
            sys.stderr.write(
                f"FAIL h264_decode_core MC reachability red/green: baseline missing REACHABLE line for {mod}\n"
            )
            return 1

    failures = 0
    try:
        for mod in REQUIRED:
            sites = MUTATIONS[mod]
            for name, text in sites:
                path = RTL / name
                body = path.read_text()
                count = body.count(text)
                if count != 1:
                    sys.stderr.write(
                        f"FAIL h264_decode_core MC reachability red/green: {mod} "
                        f"instantiation anchor occurs {count}x in {name}: {text!r}\n"
                    )
                    return 1
                path.write_text(body.replace(text, text.replace(mod, mod + MUTANT_SUFFIX, 1), 1))

            red_rc, red_out = run_gate()
            marker = f"REQUIRED_RTL_MODULE_UNREACHABLE {mod} "
            if red_rc == 0 or marker not in red_out:
                sys.stderr.write(
                    f"FAIL h264_decode_core MC reachability red/green: cutting the product "
                    f"instantiation of {mod} did not turn the gate red "
                    f"(rc={red_rc})\n{red_out}"
                )
                failures += 1
            else:
                print(
                    f"OK h264_decode_core MC reachability red-check: {mod} "
                    f"unreachable when its {len(sites)} product instantiation site(s) are cut (rc={red_rc})",
                    flush=True,
                )

            for name in {n for n, _ in sites}:
                (RTL / name).write_text(originals[name])

            restored_rc, restored_out = run_gate()
            if restored_rc != 0:
                sys.stderr.write(
                    f"FAIL h264_decode_core MC reachability red/green: restoring {mod} "
                    f"did not turn the gate green again (rc={restored_rc})\n" + restored_out
                )
                failures += 1
    finally:
        for name, body in originals.items():
            if (RTL / name).read_text() != body:
                (RTL / name).write_text(body)

    final_rc, final_out = run_gate()
    if final_rc != 0:
        sys.stderr.write(
            "FAIL h264_decode_core MC reachability red/green: sources not restored cleanly\n" + final_out
        )
        return 1
    if failures:
        return 1

    print(
        "OK h264_decode_core MC reachability red/green: "
        f"{len(REQUIRED)}/{len(REQUIRED)} required modules proved reachable via a mutated-red edge; "
        + final_out.strip().splitlines()[-1]
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
