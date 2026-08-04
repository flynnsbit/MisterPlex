#!/usr/bin/env python3
"""Static unit: DIAG_TAG_RCA PLXF upper-word pack (I1/I2).

SSOT design card:
  Memory/lab/patches/diag_i1_i2_tag_rca.patch.CARD.txt
  Memory/lab/patches/diag_i1_i2_tag_rca.patch

Product PLXF (DIAG_TAG_RCA=0, default):
  DDRAM_DIN <= {frame_status_ddr, frame_mbox_seq+1, MAGIC_F}
  frame_status_ddr = {frame_underrun_ddr[15:0], debug_state[7:0]}
  → [63:48]=underrun  [47:40]=debug  [39:32]=seq  [31:0]=MAGIC_F

DIAG PLXF (DIAG_TAG_RCA=1 sole instrument; DIAG ≠ product PASS):
  frame_status_ddr = {occ_disp_y[4:0], occ_prep_y[4:0], bank_mm_disp[5:0],
                      any_hit, miss_both, miss_y_only, miss_c_only, state_ddr[3:0]}
  → [63:59] occ_disp_y   [58:54] occ_prep_y   [53:48] bank_mm_disp
  → [47] any_hit  [46] miss_both  [45] miss_y_only  [44] miss_c_only  [43:40] state
  → [39:32] seq  [31:0] MAGIC_F   (unchanged)
  underrun field REPURPOSED — do not score product underrun under DIAG.

Parent decode (hi = word>>32):
  i1       = (hi >> 8) & 0xFF
  occ_disp = (hi >> 27) & 0x1F
  occ_prep = (hi >> 22) & 0x1F
  bank_mm  = (hi >> 16) & 0x3F

POSITIVE:
  - Pure pack/unpack of DIAG fields matches card bit lanes
  - MAGIC + seq lanes identical under product vs DIAG packs
  - When RTL present: param default 0; DIAG pack branch; product else branch;
    I1 sticky + I2 occupancy surfaces; format_error still 0xE1

NEGATIVE:
  - Product underrun host decode of a DIAG word must NOT equal true underrun
  - Swapped I2 field order must not match parent decode
  - DIAG_TAG_RCA default must not be 1 (product wire)

Modes:
  - Always: pack math (hard)
  - If ddr_frame_store has DIAG_TAG_RCA: full RTL structure (hard)
  - If absent: PREP_PACK_OK / DIAG_RTL_ABSENT (exit 0) — land gate documented,
    not a soft-skip of a failed assert
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = Path(
    os.environ.get(
        "DDR_FRAME_STORE",
        ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv",
    )
)
MAGIC = 0x504C5846  # PLXF


def fail(msg: str) -> int:
    print(f"FAIL diag_tag_rca_pack_static: {msg}", file=sys.stderr)
    return 1


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def code_only(text: str) -> str:
    out = []
    for ln in text.splitlines():
        out.append(ln.split("//", 1)[0])
    return "\n".join(out)


def pack_diag(
    occ_disp: int,
    occ_prep: int,
    bank_mm: int,
    any_hit: int,
    miss_both: int,
    miss_y_only: int,
    miss_c_only: int,
    state: int,
    seq: int,
) -> int:
    """Mirror DIAG frame_status_ddr + seq + MAGIC_F."""
    i2 = (
        ((occ_disp & 0x1F) << 11)
        | ((occ_prep & 0x1F) << 6)
        | (bank_mm & 0x3F)
    )  # 16 bits → [63:48]
    i1 = (
        ((any_hit & 1) << 7)
        | ((miss_both & 1) << 6)
        | ((miss_y_only & 1) << 5)
        | ((miss_c_only & 1) << 4)
        | (state & 0xF)
    )  # 8 bits → [47:40]
    status24 = ((i2 & 0xFFFF) << 8) | (i1 & 0xFF)
    hi = ((status24 & 0xFFFFFF) << 8) | (seq & 0xFF)
    return (hi << 32) | MAGIC


def pack_product(underrun: int, debug: int, seq: int) -> int:
    status24 = ((underrun & 0xFFFF) << 8) | (debug & 0xFF)
    hi = ((status24 & 0xFFFFFF) << 8) | (seq & 0xFF)
    return (hi << 32) | MAGIC


def decode_diag_parent(word: int) -> dict[str, int]:
    """Parent decode from design card (hi = word>>32)."""
    if (word & 0xFFFFFFFF) != MAGIC:
        raise ValueError("bad magic")
    hi = (word >> 32) & 0xFFFFFFFF
    return {
        "seq": hi & 0xFF,
        "i1": (hi >> 8) & 0xFF,
        "bank_mm": (hi >> 16) & 0x3F,
        "occ_prep": (hi >> 22) & 0x1F,
        "occ_disp": (hi >> 27) & 0x1F,
        "any_hit": (hi >> 15) & 1,
        "miss_both": (hi >> 14) & 1,
        "miss_y_only": (hi >> 13) & 1,
        "miss_c_only": (hi >> 12) & 1,
        "state": (hi >> 8) & 0xF,
        "host_underrun_lane": (hi >> 16) & 0xFFFF,  # product underrun lane
        "host_debug_lane": (hi >> 8) & 0xFF,
    }


def decode_product_host(word: int) -> dict[str, int]:
    if (word & 0xFFFFFFFF) != MAGIC:
        raise ValueError("bad magic")
    return {
        "seq": (word >> 32) & 0xFF,
        "debug_state": (word >> 40) & 0xFF,
        "underrun_count": (word >> 48) & 0xFFFF,
    }


def main() -> int:
    # --- Pure pack math (always hard) ---
    # Synthetic DIAG sample:
    #   occ_disp=0x0A, occ_prep=0x03, bank_mm=0x05
    #   any_hit=1, miss_both=0, miss_y_only=1, miss_c_only=0, state=0x2, seq=0xE1
    w = pack_diag(
        occ_disp=0x0A,
        occ_prep=0x03,
        bank_mm=0x05,
        any_hit=1,
        miss_both=0,
        miss_y_only=1,
        miss_c_only=0,
        state=0x2,
        seq=0xE1,
    )
    d = decode_diag_parent(w)
    if d["occ_disp"] != 0x0A:
        return fail(f"occ_disp want 0x0A got {d['occ_disp']:#x}")
    if d["occ_prep"] != 0x03:
        return fail(f"occ_prep want 0x03 got {d['occ_prep']:#x}")
    if d["bank_mm"] != 0x05:
        return fail(f"bank_mm want 0x05 got {d['bank_mm']:#x}")
    if d["any_hit"] != 1 or d["miss_both"] != 0 or d["miss_y_only"] != 1 or d["miss_c_only"] != 0:
        return fail(f"I1 sticky bits wrong: {d}")
    if d["state"] != 0x2:
        return fail(f"state want 0x2 got {d['state']:#x}")
    if d["seq"] != 0xE1:
        return fail(f"seq want 0xE1 got {d['seq']:#x}")
    # i1 nibble layout: {any, both, y_only, c_only, state[3:0]} = 0b1010_0010 = 0xA2
    if d["i1"] != 0xA2:
        return fail(f"i1 want 0xA2 got {d['i1']:#x}")

    # MAGIC + seq must match product packing of same seq
    wp = pack_product(underrun=0xFFFF, debug=0x12, seq=0xE1)
    if (wp & 0xFFFFFFFF) != MAGIC or (w & 0xFFFFFFFF) != MAGIC:
        return fail("MAGIC_F must remain 0x504C5846 under both packs")
    if ((wp >> 32) & 0xFF) != 0xE1 or ((w >> 32) & 0xFF) != 0xE1:
        return fail("seq lane [39:32] must be identical product vs DIAG")

    # NEGATIVE: product host underrun of DIAG word is NOT a real underrun score
    host = decode_product_host(w)
    # host underrun = {occ_disp, occ_prep, bank_mm} = 0x0A << 11 | 0x03 << 6 | 0x05 = 0x50C5
    expect_fake_underrun = ((0x0A & 0x1F) << 11) | ((0x03 & 0x1F) << 6) | (0x05 & 0x3F)
    if host["underrun_count"] != expect_fake_underrun:
        return fail(
            f"product underrun lane of DIAG word want {expect_fake_underrun:#x} "
            f"got {host['underrun_count']:#x}"
        )
    if host["underrun_count"] == 0xFFFF:
        return fail("NEGATIVE broken: DIAG pack must not look like sticky FFFF underrun by accident")
    if host["debug_state"] != 0xA2:
        return fail(f"product debug lane of DIAG word want i1=0xA2 got {host['debug_state']:#x}")

    # NEGATIVE: swap occ_disp/occ_prep in pack → parent must disagree
    w_swap = pack_diag(
        occ_disp=0x03,  # swapped
        occ_prep=0x0A,
        bank_mm=0x05,
        any_hit=1,
        miss_both=0,
        miss_y_only=1,
        miss_c_only=0,
        state=0x2,
        seq=0xE1,
    )
    d_swap = decode_diag_parent(w_swap)
    if d_swap["occ_disp"] == d["occ_disp"] and d_swap["occ_prep"] == d["occ_prep"]:
        return fail("DEGENERACY: swapped I2 occ fields decoded identically")

    # Distinct DIAG words → distinct decode
    w2 = pack_diag(1, 2, 3, 0, 1, 0, 0, 0x4, 1)
    if decode_diag_parent(w2) == d:
        return fail("DEGENERACY: distinct DIAG packs decoded identically")

    # Wrong magic
    try:
        decode_diag_parent((w & ~0xFFFFFFFF) | 0xDEADBEEF)
        return fail("wrong magic must raise")
    except ValueError:
        pass

    # --- RTL bind (optional until DIAG lands in tree) ---
    rtl_status = "ABSENT"
    if not STORE.is_file():
        print("PASS diag_tag_rca_pack_static: PREP_PACK_OK pack-math only")
        print(f"  DIAG_RTL=ABSENT store={STORE}")
        print("  GATE: full RTL bind after DIAG_TAG_RCA lands in ddr_frame_store.sv")
        print(f"  sample_diag_word=0x{w:016X} i1=0x{d['i1']:02X} "
              f"occ_disp={d['occ_disp']} occ_prep={d['occ_prep']} bank_mm={d['bank_mm']}")
        print("  DIAG≠product PASS; underrun lane repurposed under DIAG")
        return 0

    rtl = STORE.read_text(encoding="utf-8", errors="replace")
    if "DIAG_TAG_RCA" not in rtl:
        print("PASS diag_tag_rca_pack_static: PREP_PACK_OK pack-math only")
        print(f"  DIAG_RTL=ABSENT store={STORE}")
        print("  GATE: full RTL bind after DIAG_TAG_RCA lands in ddr_frame_store.sv")
        print(f"  sample_diag_word=0x{w:016X} i1=0x{d['i1']:02X} "
              f"occ_disp={d['occ_disp']} occ_prep={d['occ_prep']} bank_mm={d['bank_mm']}")
        print("  DIAG≠product PASS; underrun lane repurposed under DIAG")
        return 0

    rtl_status = "PRESENT"
    code = code_only(rtl)
    compact = nt(code)

    # Param default must be 0 (product-identical unless sole DIAG=1)
    if not re.search(r"parameter\s+bit\s+DIAG_TAG_RCA\s*=\s*1'b0", rtl):
        return fail("DIAG_TAG_RCA parameter must default to 1'b0 (product wire)")
    # NEGATIVE: must not default to 1
    if re.search(r"parameter\s+bit\s+DIAG_TAG_RCA\s*=\s*1'b1", rtl):
        return fail("DIAG_TAG_RCA must not default to 1'b1 on product source")

    # I1 sticky regs
    for name in (
        "miss_y_only_sticky",
        "miss_c_only_sticky",
        "miss_both_sticky",
        "any_hit_sticky",
    ):
        if name not in rtl:
            return fail(f"I1 sticky reg missing: {name}")

    # I1 update under miss_d && has_frame
    if "miss_y_only_sticky" not in code or "miss_d" not in code:
        return fail("I1 sticky update must reference miss_d path")
    if not re.search(r"miss_d\s*&&\s*has_frame", code):
        return fail("I1 sticky must arm on miss_d && has_frame")

    # I2 occupancy combo
    for name in ("occ_disp_y_c", "occ_prep_y_c", "bank_mm_disp_c", "occ_disp_y_r", "occ_prep_y_r"):
        if name not in rtl:
            return fail(f"I2 surface missing: {name}")
    if "cur_base_idx" not in rtl or "prep_base_idx" not in rtl:
        return fail("I2 must walk cur_base_idx / prep_base_idx halves")

    # debug_state DIAG ternary + format_error force 0xE1 path
    # (patterns target whitespace-stripped `compact`)
    if "DEBUG_FORMAT_ERROR" not in rtl:
        return fail("format_error debug path must remain (0xE1)")
    if "assigndebug_state=format_error?DEBUG_FORMAT_ERROR" not in compact:
        return fail("debug_state must still force DEBUG_FORMAT_ERROR on format_error")
    # DIAG branch of debug_state uses sticky s2 + state_ddr
    if (
        "DIAG_TAG_RCA?{any_hit_s2,miss_both_s2,miss_y_only_s2,miss_c_only_s2,state_ddr}"
        not in compact
    ):
        return fail(
            "debug_state DIAG arm must be "
            "{any_hit_s2, miss_both_s2, miss_y_only_s2, miss_c_only_s2, state_ddr}"
        )

    # frame_status pack branches
    if (
        "if(DIAG_TAG_RCA)frame_status_ddr<={occ_disp_y_r,occ_prep_y_r,bank_mm_disp_r,"
        "any_hit_s2,miss_both_s2,miss_y_only_s2,miss_c_only_s2,state_ddr}"
        not in compact
    ):
        return fail(
            "DIAG frame_status_ddr pack must be "
            "{occ_disp_y_r, occ_prep_y_r, bank_mm_disp_r, any_hit_s2, "
            "miss_both_s2, miss_y_only_s2, miss_c_only_s2, state_ddr}"
        )
    if "frame_status_ddr<={frame_underrun_ddr,debug_state}" not in compact:
        return fail("product else pack must remain {frame_underrun_ddr, debug_state}")

    # PLXF write keeps MAGIC + seq (status24 + seq + MAGIC)
    if "DDRAM_DIN<={frame_status_ddr,frame_mbox_seq+8'd1,MAGIC_F}" not in compact:
        return fail(
            "PLXF DIN must stay {frame_status_ddr, frame_mbox_seq + 8'd1, MAGIC_F} "
            "(MAGIC/seq path unchanged)"
        )

    # CDC 2-FF for sticky 0→1
    for a, b in (
        ("miss_y_only_s1", "miss_y_only_s2"),
        ("miss_c_only_s1", "miss_c_only_s2"),
        ("miss_both_s1", "miss_both_s2"),
        ("any_hit_s1", "any_hit_s2"),
    ):
        if a not in rtl or b not in rtl:
            return fail(f"I1 CDC pair missing: {a}/{b}")

    print("PASS diag_tag_rca_pack_static:")
    print(f"  DIAG_RTL={rtl_status} store={STORE}")
    print("  pack: [63:59]occ_disp [58:54]occ_prep [53:48]bank_mm")
    print("        [47]any_hit [46]miss_both [45]miss_y [44]miss_c [43:40]state")
    print("        [39:32]seq [31:0]MAGIC_F")
    print(f"  sample_diag_word=0x{w:016X} i1=0x{d['i1']:02X} "
          f"occ_disp={d['occ_disp']} occ_prep={d['occ_prep']} bank_mm={d['bank_mm']}")
    print(f"  product_host_on_diag underrun={host['underrun_count']:#x} "
          f"(NOT product underrun — lane repurposed)")
    print("  RTL: DIAG_TAG_RCA default 0; DIAG/product frame_status branches; "
          "I1 sticky+CDC; I2 occ; MAGIC/seq hold; format_error 0xE1")
    print("  DIAG≠product PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
