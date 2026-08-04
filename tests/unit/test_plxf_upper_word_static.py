#!/usr/bin/env python3
"""Static + host-decode unit: PLXF upper-word pack (underrun/debug/seq).

Tip RTL (ddram_frame_rd.sv PLXF / underrun mailbox DIN):
  DDRAM_DIN <= {frame_underrun_count,   // [63:48]
                frame_sdram_state,      // [47:40] debug_state
                frame_mbox_seq + 8'd1,  // [39:32] published seq
                MAGIC_F};               // [31:0]  0x504C5846 "PLXF"

Host decodeFrameStoreStatusWord (input_mailbox.hpp):
  seq            ← word[39:32]
  debug_state    ← word[47:40]
  underrun_count ← word[63:48]

Live lab sample (parent-settled, PRODUCT_WIRE=0, no device this lane):
  upper word 0xFFFF12E1 → underrun=0xFFFF, debug=0x12, seq=0xE1
  (full 64-bit: 0xFFFF12E1504C5846)

POSITIVE:
  - RTL concat order underrun, frame_sdram_state, seq+1, MAGIC_F
  - Host field extract matches bit lanes
  - Live sample decodes as above

NEGATIVE:
  - Mis-ordered pack (debug in [63:48]) must not match live sample decode
  - Wrong magic must fail host decode
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RD = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddram_frame_rd.sv"
IMBOX = ROOT / "host" / "libmisterplex" / "input_mailbox.hpp"
SPEC = ROOT / "host" / "libmisterplex" / "mailbox_abi_spec.hpp"
UNIT = ROOT / "tests" / "unit" / "test_input_mailbox.cpp"

MAGIC = 0x504C5846  # PLXF
# Parent-settled live upper word (hi half of PLXF mailbox).
LIVE_UPPER = 0xFFFF12E1


def fail(msg: str) -> int:
    print(f"FAIL plxf_upper_word_static: {msg}", file=sys.stderr)
    return 1


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def extract_plxf_din(src: str) -> str:
    # RTL may pad spaces: "DDRAM_DIN      <= {frame_underrun_count, ..."
    for m in re.finditer(r"DDRAM_DIN\s*<=\s*", src):
        chunk = src[m.end() : m.end() + 400]
        if "MAGIC_F" in chunk and "frame_underrun_count" in chunk:
            return chunk
    return ""


def pack_plxf(underrun: int, debug: int, seq: int) -> int:
    """Mirror RTL: {underrun[15:0], debug[7:0], seq[7:0], MAGIC_F}."""
    hi = (
        ((underrun & 0xFFFF) << 16)
        | ((debug & 0xFF) << 8)
        | (seq & 0xFF)
    )
    return (hi << 32) | MAGIC


def decode_plxf_host(word: int) -> dict[str, int]:
    """Mirror host/libmisterplex/input_mailbox.hpp decodeFrameStoreStatusWord."""
    if (word & 0xFFFFFFFF) != MAGIC:
        raise ValueError("bad magic")
    return {
        "seq": (word >> 32) & 0xFF,
        "debug_state": (word >> 40) & 0xFF,
        "underrun_count": (word >> 48) & 0xFFFF,
    }


def main() -> int:
    for p in (RD, IMBOX, SPEC, UNIT):
        if not p.is_file():
            return fail(f"missing {p}")

    rtl = RD.read_text(encoding="utf-8", errors="replace")
    imbox = IMBOX.read_text(encoding="utf-8", errors="replace")
    spec = SPEC.read_text(encoding="utf-8", errors="replace")
    unit = UNIT.read_text(encoding="utf-8", errors="replace")

    # --- RTL pack ---
    din = extract_plxf_din(rtl)
    if not din:
        return fail("PLXF DDRAM_DIN assignment with MAGIC_F + frame_underrun_count not found")
    compact = nt(din)
    # Concat order: underrun first (MSB), then frame_sdram_state, then seq+1, MAGIC_F last.
    if not re.search(
        r"\{frame_underrun_count,frame_sdram_state,frame_mbox_seq\+8'?d1,MAGIC_F\}",
        compact,
    ):
        return fail(
            "PLXF DIN must be {frame_underrun_count, frame_sdram_state, "
            "frame_mbox_seq + 8'd1, MAGIC_F}"
        )
    # Header comment must document bit lanes.
    if "[63:48]" not in rtl or "underrun" not in rtl.lower():
        return fail("ddram_frame_rd must document [63:48] underrun in PLXF comment")
    if "[47:40]" not in rtl:
        return fail("ddram_frame_rd must document [47:40] debug/state in PLXF comment")
    if "[39:32]" not in rtl:
        return fail("ddram_frame_rd must document [39:32] seq in PLXF comment")
    if "MAGIC_F" not in rtl or "504C_5846" not in rtl and "504C5846" not in rtl:
        return fail("MAGIC_F must be 0x504C5846")
    # NEGATIVE class: state must not lead the concat (would put debug into [63:48]).
    if re.search(r"DDRAM_DIN\s*<=\s*\{\s*frame_sdram_state\b", rtl):
        return fail("frame_sdram_state must not lead PLXF DIN (would steal underrun lane)")

    # --- Spec / magic ---
    if "kPlxfMagic" not in spec or "0x504C5846" not in spec:
        return fail("mailbox_abi_spec must define kPlxfMagic = 0x504C5846")
    if "PLXF" not in spec:
        return fail("mailbox_abi_spec must name PLXF")

    # --- Host decode surface ---
    if "decodeFrameStoreStatusWord" not in imbox:
        return fail("input_mailbox missing decodeFrameStoreStatusWord")
    if not re.search(
        r"out\.seq\s*=\s*static_cast<uint8_t>\s*\(\s*\(\s*word\s*>>\s*32\s*\)\s*&\s*0xFFu\s*\)",
        imbox,
    ):
        return fail("host seq must be (word>>32)&0xFF → [39:32]")
    if not re.search(
        r"out\.debug_state\s*=\s*static_cast<uint8_t>\s*\(\s*\(\s*word\s*>>\s*40\s*\)\s*&\s*0xFFu\s*\)",
        imbox,
    ):
        return fail("host debug_state must be (word>>40)&0xFF → [47:40]")
    if not re.search(
        r"out\.underrun_count\s*=\s*static_cast<uint16_t>\s*\(\s*\(\s*word\s*>>\s*48\s*\)\s*&\s*0xFFFFu\s*\)",
        imbox,
    ):
        return fail("host underrun_count must be (word>>48)&0xFFFF → [63:48]")

    # --- C++ unit must keep live-sample / RTL upper-word coverage ---
    if "0xFFFF12E1" not in unit and "FFFF12E1" not in unit:
        return fail("test_input_mailbox must document live upper 0xFFFF12E1")
    if "decodeFrameStoreStatusWord" not in unit:
        return fail("test_input_mailbox must exercise decodeFrameStoreStatusWord")

    # --- Behavioral host decode ---
    w = pack_plxf(underrun=0x0011, debug=0xE1, seq=4)
    d = decode_plxf_host(w)
    if d != {"seq": 4, "debug_state": 0xE1, "underrun_count": 0x0011}:
        return fail(f"pack/decode roundtrip want seq=4 debug=0xE1 underrun=0x11 got {d}")

    # Live sample upper-only → full word with MAGIC_F
    live_word = (LIVE_UPPER << 32) | MAGIC
    # Sanity: LIVE_UPPER bits
    # underrun = FFFF, debug = 12, seq = E1
    live = decode_plxf_host(live_word)
    if live["underrun_count"] != 0xFFFF:
        return fail(f"live 0xFFFF12E1 underrun want 0xFFFF got {live['underrun_count']:#x}")
    if live["debug_state"] != 0x12:
        return fail(f"live 0xFFFF12E1 debug want 0x12 got {live['debug_state']:#x}")
    if live["seq"] != 0xE1:
        return fail(f"live 0xFFFF12E1 seq want 0xE1 got {live['seq']:#x}")
    if pack_plxf(0xFFFF, 0x12, 0xE1) != live_word:
        return fail("pack_plxf(FFFF,12,E1) must equal live word")

    # Degeneracy: three distinct uppers → distinct field triples
    triples = [
        decode_plxf_host(pack_plxf(1, 0x10, 1)),
        decode_plxf_host(pack_plxf(2, 0x20, 2)),
        decode_plxf_host(pack_plxf(0xFFFF, 0x12, 0xE1)),
    ]
    if triples[0] == triples[1] or triples[1] == triples[2]:
        return fail("DEGENERACY: distinct PLXF words decoded identically")

    # NEGATIVE: wrong magic
    try:
        decode_plxf_host((LIVE_UPPER << 32) | 0xDEADBEEF)
        return fail("wrong magic must raise")
    except ValueError:
        pass

    # NEGATIVE: if underrun and debug lanes were swapped in host extract, live would
    # report underrun=0x12E1 and debug=0xFF (not the settled FFFF / 0x12).
    swapped_underrun = (live_word >> 32) & 0xFFFF  # correct underrun lane
    swapped_as_if_debug_in_msb = (live_word >> 48) & 0xFF  # would be if debug led
    if swapped_underrun != 0xFFFF or swapped_as_if_debug_in_msb == 0x12:
        # second clause: if someone took [63:56] as debug they'd get 0xFF not 0x12
        pass
    fake_debug_from_msb = (LIVE_UPPER >> 24) & 0xFF  # 0xFF
    fake_underrun_from_low = LIVE_UPPER & 0xFFFF  # 0x12E1
    if fake_debug_from_msb == 0x12 or fake_underrun_from_low == 0xFFFF:
        return fail("negative twin setup broken for mis-lane check")
    if live["debug_state"] == fake_debug_from_msb:
        return fail("debug_state collapsed onto MSB byte (lane bug)")
    if live["underrun_count"] == fake_underrun_from_low:
        return fail("underrun_count collapsed onto low 16 of upper (lane bug)")

    print("PASS plxf_upper_word_static:")
    print("  RTL: [63:48]=frame_underrun_count, [47:40]=frame_sdram_state,")
    print("       [39:32]=frame_mbox_seq+1, [31:0]=MAGIC_F")
    print("  host: seq←[39:32], debug_state←[47:40], underrun_count←[63:48]")
    print(
        f"  live upper=0x{LIVE_UPPER:08X} → underrun={live['underrun_count']:04X} "
        f"debug=0x{live['debug_state']:02X} seq=0x{live['seq']:02X}"
    )
    print(f"  full word=0x{live_word:016X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
