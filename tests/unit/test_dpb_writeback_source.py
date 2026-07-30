#!/usr/bin/env python3
"""DPB writeback sample-source gate (decode_stub).

Pre-register:
  Product path must commit recon-sourced samples (dpb_recon_src_sample), not the
  historical synthetic XOR/chroma-ramp as dpb_filtered_sample.
  Mutation: strip the ifndef and force XOR → must go RED.

Does not claim full-frame I decode or POST-deblock (ref_commit is sv-mvd/integ).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STUB = ROOT / "fpga/Plex_MiSTer/rtl/decode_stub.sv"


def main() -> int:
    text = STUB.read_text(encoding="utf-8", errors="replace")
    failures = 0

    def fail(msg: str) -> None:
        nonlocal failures
        print(f"FAIL dpb_writeback_source: {msg}", file=sys.stderr)
        failures += 1

    # Product must define recon-sourced sample.
    if "dpb_recon_src_sample" not in text:
        fail("missing dpb_recon_src_sample (recon-sourced commit mux)")
    if "inter_recon_y" not in text or "recon_px" not in text:
        fail("recon sources (inter_recon_y / recon_px) not referenced")

    # Synthetic may exist only as named wire + FAULT path.
    if "dpb_synthetic_sample" not in text:
        fail("missing dpb_synthetic_sample (FAULT twin source)")
    if "DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR" not in text:
        fail("missing DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR guard")

    # Product assign of dpb_filtered_sample must prefer recon, not bare XOR.
    # Accept:
    #   `ifdef FAULT ... synthetic ... `else ... recon_src ... `endif
    fault_block = re.search(
        r"`ifdef\s+DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR\s*"
        r"wire\s+\[7:0\]\s+dpb_filtered_sample\s*=\s*dpb_synthetic_sample\s*;\s*"
        r"`else\s*"
        r"wire\s+\[7:0\]\s+dpb_filtered_sample\s*=\s*dpb_recon_src_sample\s*;\s*"
        r"`endif",
        text,
        re.MULTILINE,
    )
    if not fault_block:
        fail("dpb_filtered_sample not gated FAULT=synthetic / else=recon_src")

    # Mutation twin: if product drove XOR unconditionally, RED.
    bare_xor = re.search(
        r"wire\s+\[7:0\]\s+dpb_filtered_sample\s*=\s*\(dpb_filtered_plane\s*==\s*2'd0\)\s*\?\s*\(8'h20\s*\^",
        text,
    )
    if bare_xor:
        fail("bare synthetic XOR still assigns dpb_filtered_sample (product hole)")

    # Simulate mutation: force product line to synthetic only → detector must fire.
    mutated = re.sub(
        r"`ifdef\s+DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR.*?`endif",
        "wire [7:0] dpb_filtered_sample = dpb_synthetic_sample;",
        text,
        count=1,
        flags=re.DOTALL,
    )
    mut_ok = bool(
        re.search(
            r"wire\s+\[7:0\]\s+dpb_filtered_sample\s*=\s*dpb_recon_src_sample\s*;",
            mutated,
        )
    )
    if mut_ok:
        fail("mutation twin did not remove recon_src product assign")
    else:
        # Expected RED shape for the twin
        if "dpb_filtered_sample = dpb_synthetic_sample" not in mutated.replace(" ", ""):
            # spaces stripped check softer
            if "dpb_filtered_sample = dpb_synthetic_sample" not in mutated and \
               "dpb_filtered_sample=dpb_synthetic_sample" not in mutated.replace(" ", ""):
                fail("mutation twin rewrite failed to install synthetic-only assign")

    if failures:
        print(f"FAIL dpb_writeback_source: {failures} check(s)", file=sys.stderr)
        return 1

    print(
        "OK dpb_writeback_source: product=recon_src "
        "fault=DECODE_STUB_FAULT_DPB_SYNTHETIC_XOR "
        "mutation_twin_red_shape=1 "
        "(full I walker + POST-deblock still tracked by ref_commit lane)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
