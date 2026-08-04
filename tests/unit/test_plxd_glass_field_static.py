#!/usr/bin/env python3
"""Static + host-decode unit: PLXD glass_vsync field vs frames_done.

Tip land (bbbd25fe stack):
  RTL pack (ddr_frame_store.sv PLXD DIN):
    [63:48] frames_done_d2          — real bank swaps (CDC)
    [47:36] bank_vsync_count[11:0]  — glass/vsync free-run LSBs
  Host decodeBankReleaseWord / fpga_spi readBankRelease:
    glass_vsync_count ← word[47:36]
    frames_done       ← word[63:48]

POSITIVE:
  - RTL packs frames_done_d2 first, bank_vsync_count[11:0] second (not c5382bee)
  - mailbox_abi bit constants: glass bit=4 width=12; frames_done bit=16 width=16
  - host/input_mailbox decode extracts independent fields
  - arm fpga_spi.cpp uses (raw_hi>>4)&0x0FFF for glass, >>16 for frames_done

NEGATIVE:
  - A word with glass=0xABC and frames_done=7 must not decode glass into frames_done
  - Packing bank_vsync as the [63:48] field (c5382bee class) must fail RTL check
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv"
SPEC = ROOT / "host" / "libmisterplex" / "mailbox_abi_spec.hpp"
IMBOX = ROOT / "host" / "libmisterplex" / "input_mailbox.hpp"
SPI = ROOT / "arm" / "misterplexd" / "fpga_spi.cpp"

MAGIC = 0x504C5844  # PLXD


def fail(msg: str) -> int:
    print(f"FAIL plxd_glass_field_static: {msg}", file=sys.stderr)
    return 1


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def cpp_constexpr_unsigned(text: str, name: str) -> int | None:
    m = re.search(
        rf"constexpr\s+unsigned\s+{re.escape(name)}\s*=\s*(\d+)\s*;",
        text,
    )
    return int(m.group(1)) if m else None


def extract_plxd_din(src: str) -> str:
    for chunk in src.split("DDRAM_DIN <="):
        if "MAGIC_D" in chunk[:500]:
            return chunk[:500]
    return ""


def decode_plxd_host(word: int) -> dict[str, int | bool]:
    """Mirror host/libmisterplex/input_mailbox.hpp decodeBankReleaseWord."""
    if (word & 0xFFFFFFFF) != MAGIC:
        raise ValueError("bad magic")
    hi = (word >> 32) & 0xFFFFFFFF
    # Constants from mailbox_abi_spec (asserted separately).
    glass_bit, glass_w = 4, 12
    fd_bit, fd_w = 16, 16
    return {
        "free_bank_mask": hi & 0x3,
        "disp_bank": (hi >> 2) & 1,
        "swap_pending": bool((hi >> 3) & 1),
        "glass_vsync_count": (hi >> glass_bit) & ((1 << glass_w) - 1),
        "frames_done": (hi >> fd_bit) & ((1 << fd_w) - 1),
    }


def pack_plxd(frames_done: int, glass: int, swap: int, disp: int, free_mask: int) -> int:
    hi = (
        (frames_done & 0xFFFF) << 16
        | (glass & 0x0FFF) << 4
        | (swap & 1) << 3
        | (disp & 1) << 2
        | (free_mask & 3)
    )
    return (hi << 32) | MAGIC


def main() -> int:
    for p in (STORE, SPEC, IMBOX, SPI):
        if not p.is_file():
            return fail(f"missing {p}")

    store = STORE.read_text(encoding="utf-8", errors="replace")
    spec = SPEC.read_text(encoding="utf-8", errors="replace")
    imbox = IMBOX.read_text(encoding="utf-8", errors="replace")
    spi = SPI.read_text(encoding="utf-8", errors="replace")

    # --- RTL pack ---
    plxd = extract_plxd_din(store)
    if not plxd:
        return fail("PLXD DDRAM_DIN assignment with MAGIC_D not found")
    compact = nt(plxd)
    if not (
        compact.startswith("{frames_done_d2,")
        or "{frames_done_d2," in compact[:40]
    ):
        return fail("PLXD [63:48] must pack frames_done_d2 first (not bank_vsync)")
    if "bank_vsync_count[11:0]" not in plxd and "bank_vsync_count[11:0]" not in compact:
        return fail("PLXD [47:36] must pack bank_vsync_count[11:0] glass LSBs")
    # c5382bee class: bank_vsync as the first concat field
    if re.search(r"DDRAM_DIN\s*<=\s*\{\s*bank_vsync_count\b", store):
        return fail("c5382bee class: bank_vsync_count must not lead PLXD DIN")

    # --- ABI constants ---
    gbit = cpp_constexpr_unsigned(spec, "kPlxdGlassVsyncBit")
    gw = cpp_constexpr_unsigned(spec, "kPlxdGlassVsyncWidth")
    fbit = cpp_constexpr_unsigned(spec, "kPlxdFramesDoneBit")
    fw = cpp_constexpr_unsigned(spec, "kPlxdFramesDoneWidth")
    if gbit != 4:
        return fail(f"kPlxdGlassVsyncBit want 4 (→[47:36]), got {gbit}")
    if gw != 12:
        return fail(f"kPlxdGlassVsyncWidth want 12, got {gw}")
    if fbit != 16:
        return fail(f"kPlxdFramesDoneBit want 16 (→[63:48]), got {fbit}")
    if fw != 16:
        return fail(f"kPlxdFramesDoneWidth want 16, got {fw}")

    # Spec text must document the split fields.
    if "[47:36]" not in spec or "glass_vsync" not in spec:
        return fail("mailbox_abi_spec must document [47:36] glass_vsync")
    if "[63:48]" not in spec or "frames_done" not in spec:
        return fail("mailbox_abi_spec must document [63:48] frames_done")

    # --- Host decode surface ---
    if "glass_vsync_count" not in imbox:
        return fail("input_mailbox BankReleaseStatus missing glass_vsync_count")
    if "kPlxdGlassVsyncBit" not in imbox or "kPlxdFramesDoneBit" not in imbox:
        return fail("decodeBankReleaseWord must use kPlxdGlassVsyncBit/FramesDoneBit")
    # Order: glass from Glass bit, frames_done from FramesDone bit (independent).
    if not re.search(
        r"glass_vsync_count\s*=.*kPlxdGlassVsyncBit",
        imbox,
        flags=re.S,
    ):
        return fail("glass_vsync_count must decode via kPlxdGlassVsyncBit")
    if not re.search(
        r"frames_done\s*=.*kPlxdFramesDoneBit",
        imbox,
        flags=re.S,
    ):
        return fail("frames_done must decode via kPlxdFramesDoneBit")

    # --- ARM fpga_spi decode ---
    if "glass_vsync_count" not in spi:
        return fail("fpga_spi missing glass_vsync_count field decode")
    if not re.search(
        r"glass_vsync_count\s*=\s*static_cast<uint16_t>\s*\(\s*\(\s*d\.raw_hi\s*>>\s*4\s*\)\s*&\s*0x0FFF\s*\)",
        spi,
    ):
        return fail("fpga_spi must decode glass as (raw_hi>>4)&0x0FFF → [47:36]")
    if not re.search(
        r"frames_done\s*=\s*static_cast<uint16_t>\s*\(\s*d\.raw_hi\s*>>\s*16\s*\)",
        spi,
    ):
        return fail("fpga_spi must decode frames_done as raw_hi>>16 → [63:48]")

    # --- Behavioral host decode (independent fields) ---
    w = pack_plxd(frames_done=7, glass=0xABC, swap=1, disp=0, free_mask=0)
    # Expected upper = 0x00070ABC << wait: (7<<16)|(0xABC<<4)|(1<<3) = 0x00070AB8
    # 0xABC<<4 = 0xABC0; +8 = 0xABC8; + 0x00070000 = 0x0007ABC8 — fix:
    # 7<<16 = 0x00070000; 0xABC<<4 = 0x0ABC0; | 8 = 0x0007ABC8? 0x00070000|0xABC0|8 = 0x0007ABC8
    # Wait known good from test_input_mailbox: frames=0x1234 glass=0x0AB → 0x12340AB8
    d = decode_plxd_host(w)
    if d["frames_done"] != 7:
        return fail(f"host decode frames_done want 7 got {d['frames_done']}")
    if d["glass_vsync_count"] != 0xABC:
        return fail(f"host decode glass_vsync_count want 0xABC got {d['glass_vsync_count']}")
    if d["frames_done"] == d["glass_vsync_count"]:
        return fail("frames_done collapsed onto glass_vsync_count (field merge bug)")

    w2 = pack_plxd(frames_done=0x1234, glass=0x0AB, swap=1, disp=0, free_mask=0)
    d2 = decode_plxd_host(w2)
    if d2["frames_done"] != 0x1234 or d2["glass_vsync_count"] != 0x0AB:
        return fail(f"host decode mismatch d2={d2}")
    # Known RTL cross-check word from tip pack docs
    rtl_word_b = 0x12340AB800000000 | MAGIC
    d3 = decode_plxd_host(rtl_word_b)
    if d3["frames_done"] != 0x1234 or d3["glass_vsync_count"] != 0x0AB:
        return fail(f"RTL word 0x12340AB8 decode want fd=0x1234 gv=0x0AB got {d3}")

    # NEGATIVE: if someone packed glass into [63:48], host frames_done would read glass.
    # Simulate mis-pack: put glass value in frames_done field, zero glass field.
    mis = pack_plxd(frames_done=0x0ABC, glass=0, swap=0, disp=0, free_mask=2)
    dm = decode_plxd_host(mis)
    if dm["frames_done"] != 0x0ABC or dm["glass_vsync_count"] != 0:
        return fail("negative setup broken for mis-pack isolation check")
    # Positive path above already proved glass≠frames when both set; this proves
    # the bit lanes are independent (glass=0 while frames carries a glass-like value).
    if dm["glass_vsync_count"] == dm["frames_done"]:
        return fail("negative: glass and frames_done not independent")

    # NEGATIVE twin: RTL that leads with bank_vsync must fail extract check.
    fake_rtl = "DDRAM_DIN <= {bank_vsync_count, 12'd0, MAGIC_D};"
    if not re.search(r"DDRAM_DIN\s*<=\s*\{\s*bank_vsync_count\b", fake_rtl):
        return fail("negative twin regex broken")
    # (live store already checked not to match)

    print("PASS plxd_glass_field_static:")
    print("  RTL: [63:48]=frames_done_d2, [47:36]=bank_vsync_count[11:0]")
    print("  ABI: glass bit=4 w=12; frames_done bit=16 w=16")
    print("  host decode: glass_vsync_count←[47:36], frames_done←[63:48]")
    print("  arm fpga_spi: (raw_hi>>4)&0x0FFF / raw_hi>>16")
    print(
        f"  decode proof: word=0x{rtl_word_b:016x} "
        f"frames_done={d3['frames_done']:#x} glass_vsync_count={d3['glass_vsync_count']:#x}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
