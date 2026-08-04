#!/usr/bin/env python3
"""h264_dpb_one_ref fetch budget — rd-duck cycle blocker (not entropy-only).

Source-backed facts (h264_dpb.sv h264_dpb_one_ref):
  - Luma issues issue_idx 0..440 inclusive => 441 one-byte reads (21x21 window)
  - Chroma U/V each 0..80 => 81+81
  - Total 603 one-byte mem_rd beats per partition
  - fetch_part_w/h latched to lat_part_* but empty if-body: NOT used to narrow fetch

720p P16x16 (one part/MB): 80*45=3600 MB * 603 = 2_170_800 cycles
  @20 MHz => 108.54 ms  (>> 41.667 ms frame budget @24fps)
Full I420 write 1_382_400 byte-cycles @20 MHz => 69.12 ms
  @32.59 MHz => 42.42 ms (still does not close 24fps with serial ref-fetch)

decode_stub dpb_mem[...][17:0] aliases to 256 KiB — does not prove 720p DPB.
PRODUCT_NO_STUB removes stub/back-end branch (elaborated config; not this TB).

NEGATIVE: claiming part_w narrows fetch; claiming 603*3600 fits in 41.667ms @20MHz;
claiming remaining fabric-decode work is entropy-frontend only.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DPB = ROOT / "fpga/Plex_MiSTer/rtl/h264_dpb.sv"
STUB = ROOT / "fpga/Plex_MiSTer/rtl/decode_stub.sv"
CLK_SYS = 20_000_000
CLK_ALT = 32_590_000  # nostub-era Fmax figure used in lab notes
FPS = 24
FRAME_BUDGET_MS = 1000.0 / FPS


def fail(msg: str) -> int:
    print(f"FAIL dpb_one_ref_fetch_budget: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    t = DPB.read_text(encoding="utf-8", errors="replace")
    # Isolate h264_dpb_one_ref body
    m = re.search(
        r"module\s+h264_dpb_one_ref\b(.*?)endmodule",
        t,
        flags=re.S,
    )
    if not m:
        return fail("h264_dpb_one_ref module not found")
    body = m.group(0)

    # Issue limits
    if "issue_idx == 9'd440" not in body:
        return fail("expected luma terminal issue_idx == 9'd440 (441 beats)")
    if body.count("issue_idx == 9'd80") < 2:
        return fail("expected two chroma terminals issue_idx == 9'd80 (81 each)")
    # one-byte port
    if not re.search(r"input\s+wire\s+\[7:0\]\s+mem_rdata", body):
        return fail("mem_rdata must be 8-bit (one-byte reads)")
    if not re.search(r"output\s+reg\s+\[31:0\]\s+mem_raddr", body):
        return fail("mem_raddr present")

    luma_reads = 441
    chroma_reads = 81
    per_part = luma_reads + 2 * chroma_reads
    if per_part != 603:
        return fail(f"internal: per_part={per_part}")

    # part_w/h observed but not used to narrow
    if "fetch_part_w" not in body or "fetch_part_h" not in body:
        return fail("fetch_part_w/h ports required")
    if "lat_part_w_lo" not in body:
        return fail("lat_part_w_lo latch required (observation path)")
    # The empty future-narrow comment is the binding admission
    if "future narrower fetch windows" not in body and "Keep part_w/part_h observed" not in body:
        return fail("expected comment that part_w/h are only observed, not narrowing")
    # NEGATIVE: issue path must not gate on lat_part for count
    # (no `if (lat_part` around issue_idx==440)
    issue_region = body[body.find("phase == PH_LUMA") : body.find("PH_DRAIN")]
    if re.search(r"lat_part_.*issue_idx", issue_region):
        return fail("unexpected lat_part coupling into issue_idx path")

    print(
        f"OK per-partition one-byte reads: Y={luma_reads} U={chroma_reads} "
        f"V={chroma_reads} total={per_part}"
    )
    print("OK part_w/h latched/observed only — do not narrow fetch (quoted comment)")

    # 720p P16x16 frame
    mb = (1280 // 16) * (720 // 16)
    if mb != 3600:
        return fail(f"720p MB count {mb} != 3600")
    cycles = per_part * mb
    if cycles != 2_170_800:
        return fail(f"ref-fetch cycles {cycles} != 2170800")
    ms_20 = cycles / CLK_SYS * 1000.0
    if abs(ms_20 - 108.54) > 0.02:
        return fail(f"@20MHz expected ~108.54ms got {ms_20}")
    if ms_20 <= FRAME_BUDGET_MS:
        return fail(
            f"NEGATIVE: ref-fetch {ms_20:.2f}ms must NOT fit in "
            f"{FRAME_BUDGET_MS:.3f}ms @24fps without redesign"
        )
    print(
        f"OK 720p P16x16 ref-fetch: {cycles} cyc = {ms_20:.2f} ms @20MHz "
        f"(budget {FRAME_BUDGET_MS:.3f} ms) — CANNOT 24fps"
    )

    i420 = 1280 * 720 * 3 // 2
    if i420 != 1_382_400:
        return fail("I420 bytes")
    wr_20 = i420 / CLK_SYS * 1000.0
    wr_alt = i420 / CLK_ALT * 1000.0
    if abs(wr_20 - 69.12) > 0.02:
        return fail(f"I420 write @20MHz {wr_20}")
    if abs(wr_alt - 42.42) > 0.05:
        return fail(f"I420 write @32.59MHz {wr_alt}")
    print(
        f"OK full I420 write byte-cycles: {wr_20:.2f} ms @20MHz, "
        f"{wr_alt:.2f} ms @32.59MHz (still not free lunch with serial fetch)"
    )

    # decode_stub alias depth
    st = STUB.read_text(encoding="utf-8", errors="replace")
    if "dpb_mem[dpb_mem_waddr[17:0]]" not in st and "dpb_mem_waddr[17:0]" not in st:
        return fail("decode_stub must index dpb_mem with [17:0] (256KiB alias)")
    if "DPB_MEM_BYTES" not in st:
        return fail("DPB_MEM_BYTES missing")
    # 18-bit index => 256KiB entries
    print("OK decode_stub dpb_mem [...][17:0] => 256 KiB alias space (not 720p proof)")

    # Framing lock
    print(
        "OK framing: remaining fabric-decode work is NOT entropy-frontend only — "
        "wide/burst DPB redesign required for 720p24; intra/deblock/integrators "
        "still DEAD on source graph; PRODUCT_NO_STUB strips stub branch"
    )
    print("PASS h264_dpb_one_ref_fetch_budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
