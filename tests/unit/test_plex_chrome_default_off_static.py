#!/usr/bin/env python3
"""G-CHROME-DEFAULT-OFF — macros unset must not paint product chrome (rd-duck).

Fails if:
  1) Boot PLXC ctrl commits enable=1 outside PLEX_FAB_BOOT_PLXC
  2) PLEX_FAB_IDLE hardwires has_frame_chrome=0 without PLEX_FAB_IDLE_FORCE
  3) plxc_ext_* is assign-tied to 0 in sys_top (dead product path)
  4) PLXG claimed at +0x130 anywhere in tree sources we own

Usage:
  python3 tests/unit/test_plex_chrome_default_off_static.py
  echo "true rc=$?"
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYS_TOP = ROOT / "fpga/Plex_MiSTer/sys/sys_top.v"
ABI = ROOT / "host/libmisterplex/mailbox_abi_spec.hpp"
CHROME = ROOT / "fpga/Plex_MiSTer/rtl/plex_chrome.sv"


def strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//.*?$", "", s, flags=re.M)
    return s


def main() -> int:
    fails = 0

    def fail(msg: str) -> None:
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", file=sys.stderr)

    def ok(msg: str) -> None:
        print(f"OK: {msg}")

    if not SYS_TOP.is_file():
        fail(f"missing {SYS_TOP}")
        return 1
    text = SYS_TOP.read_text()
    code = strip_comments(text)

    # --- 1) Default boot enable must be 0 (enable bit is host_wdata[32]) ---
    # Look for the non-BOOT_PLXC branch of boot ctrl write.
    if "PLEX_FAB_BOOT_PLXC" not in text:
        fail("sys_top missing PLEX_FAB_BOOT_PLXC gate for boot enable")
    else:
        # Outside BOOT_PLXC, the else branch must program enable=0.
        # Pattern: 1'b0 before magic 504C_5843 in the default else of boot st==1
        m = re.search(
            r"`ifdef\s+PLEX_FAB_BOOT_PLXC(.*?)`else(.*?)`endif",
            text,
            re.S,
        )
        if not m:
            fail("could not find PLEX_FAB_BOOT_PLXC ifdef/else around boot ctrl")
        else:
            else_body = m.group(2)
            # enable=1 pattern in packed PLXC: ..., 1'b1, 32'h504C_5843
            if re.search(r"1'b1\s*,\s*32'h504C_5843", else_body):
                fail("default boot branch still commits enable=1")
            elif re.search(r"1'b0\s*,\s*32'h504C_5843", else_body):
                ok("default boot PLXC enable=0")
            else:
                fail(f"default boot else body unclear:\n{else_body[:200]}")

    # --- 2) FAB_IDLE must not hardwire has_frame=0 without FORCE ---
    if "PLEX_FAB_IDLE_FORCE" not in text:
        fail("sys_top missing PLEX_FAB_IDLE_FORCE for ARM-off milestone")
    # Naked assign has_frame_chrome = 1'b0 under only FAB_IDLE is banned.
    # Acceptable: inside `ifdef PLEX_FAB_IDLE_FORCE`.
    idle_blocks = list(
        re.finditer(r"`ifdef\s+PLEX_FAB_IDLE\b(.*?)(?:`elsif|`else|`endif)", text, re.S)
    )
    if not idle_blocks:
        # FAB_IDLE may still be present with elsif structure
        if "PLEX_FAB_IDLE" not in text:
            ok("no PLEX_FAB_IDLE block (idle path absent)")
        else:
            fail("PLEX_FAB_IDLE present but block not parsed")
    else:
        body = idle_blocks[0].group(1)
        # Direct hardwire outside FORCE is a fail
        if re.search(
            r"assign\s+has_frame_chrome\s*=\s*1'b0", strip_comments(body)
        ) and "PLEX_FAB_IDLE_FORCE" not in body:
            fail("PLEX_FAB_IDLE hardwires has_frame_chrome=0 without FORCE gate")
        elif "has_frame_hdmi" in body or "PLEX_FAB_IDLE_FORCE" in body:
            ok("PLEX_FAB_IDLE uses has_frame CDC and/or FORCE gate")
        else:
            fail("PLEX_FAB_IDLE has_frame policy unclear")

    # --- 3) plxc_ext must not be local assign 0 (product path must be real nets) ---
    if re.search(r"assign\s+plxc_ext_we\s*=\s*1'b0", code):
        fail("plxc_ext_we still assign-tied to 0 in sys_top")
    elif "plxc_ext_we_sys" in text or "PLXC_EXT_WE" in text:
        ok("plxc_ext comes from emu PLXC_EXT_* (not local 0)")
    else:
        fail("no plxc_ext product path nets found")

    # --- 3b) PRODUCT compose: default else must CDC has_frame (not hardwire 1)
    # Negative twin: has_frame_chrome=1'b1 forever disables fabric idle forever.
    if re.search(r"assign\s+has_frame_chrome\s*=\s*has_frame_hdmi", code):
        ok("product compose has_frame_hdmi")
    else:
        fail("product default missing has_frame_hdmi compose")
    # PRODUCT COMPOSE block must not reintroduce stuck-1
    m_prod = re.search(r"// PRODUCT COMPOSE[\s\S]{0,600}?`endif", text)
    if m_prod and re.search(
        r"assign\s+has_frame_chrome\s*=\s*1'b1", strip_comments(m_prod.group(0))
    ):
        fail("product default hardwires has_frame_chrome=1 (idle never paints)")

    # --- 4) PLXC owns +0x130; PLXG at +0x800 in ABI (FIXED) ---
    if not ABI.is_file():
        fail(f"missing {ABI}")
    else:
        abi = ABI.read_text()
        if not re.search(r"kPlxcOffset\s*=\s*0x130u", abi):
            fail("kPlxcOffset is not 0x130")
        else:
            ok("PLXC owns +0x130")
        if not re.search(r"kPlxgOffset\s*=\s*0x800u", abi):
            fail("kPlxgOffset missing or not FIXED 0x800")
        else:
            ok("PLXG reserved at FIXED +0x800")
        if re.search(r"kPlxgOffset\s*=\s*0x130u", abi):
            fail("PLXG illegally at +0x130")
        if "static_assert(kPlxgOffset != kPlxcOffset" not in abi:
            fail("missing static_assert PLXG != PLXC")
        else:
            ok("static_assert PLXG != PLXC present")
        if "kPlxlOffset + kPlxcListMaxCmds" not in abi or "<=" not in abi:
            fail("missing list-vs-PLXG bound static_assert (not equality-to-list-end)")
        else:
            ok("list bound vs FIXED PLXG present")
        if "0x800" not in abi and "0x800u" not in abi:
            fail("PLXG freeze 0x800 not in ABI")

    # --- 5) Comment contract in chrome RTL ---
    if CHROME.is_file():
        if "+0x130" in CHROME.read_text() or "0x130" in CHROME.read_text():
            ok("plex_chrome documents PLXC +0x130")

    if fails:
        print(f"test_plex_chrome_default_off_static: {fails} FAIL(s)", file=sys.stderr)
        return 1
    print("test_plex_chrome_default_off_static: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
