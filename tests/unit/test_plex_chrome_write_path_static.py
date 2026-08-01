#!/usr/bin/env python3
"""G-CHROME-WE — plex_chrome list write path must not be dead (c74c6863 NO-DATA).

Hardware (parent, fit c74c6863):
  .list_we(1'b0) + .list_wdata(64'd0) ⇒ Quartus elides list RAM; glass HUD
  stroke histogram BYTE-IDENTICAL to pre-plane (NO-DATA).

Also: BOOT_DEMO with list_b[0]=CMD and live_bank=0 reads list_a ⇒ invisible glyph.

Usage (red-before-green — capture rc DIRECTLY):
  python3 tests/unit/test_plex_chrome_write_path_static.py --subject \\
      tests/unit/fixtures/plex_chrome_sys_top_BAD.sv.inc
  echo "true rc=$?"    # expect 1

  python3 tests/unit/test_plex_chrome_write_path_static.py --subject \\
      tests/unit/fixtures/plex_chrome_sys_top_GOOD.sv.inc
  echo "true rc=$?"    # expect 0

  python3 tests/unit/test_plex_chrome_write_path_static.py
  echo "true rc=$?"    # full suite (fixtures + RTL bank polarity)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = Path(__file__).resolve().parent / "fixtures"
BAD = FIX / "plex_chrome_sys_top_BAD.sv.inc"
GOOD = FIX / "plex_chrome_sys_top_GOOD.sv.inc"
RTL = ROOT / "fpga/Plex_MiSTer/rtl/plex_chrome.sv"
SYS_TOP = ROOT / "fpga/Plex_MiSTer/sys/sys_top.v"


def strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//.*?$", "", s, flags=re.M)
    return s


def plex_instances(text: str) -> list[str]:
    t = strip_comments(text)
    return [
        m.group(0)
        for m in re.finditer(
            r"\bplex_chrome\b\s*(?:#\s*\((.*?)\))?\s*(\w+)\s*\((.*?)\);", t, re.S
        )
    ]


def list_we_tied_off(inst: str) -> bool:
    return bool(
        re.search(r"\.list_we\s*\(\s*1?'b0\s*\)", inst)
        or re.search(r"\.list_we\s*\(\s*0\s*\)", inst)
    )


def list_wdata_const0(inst: str) -> bool:
    return bool(re.search(r"\.list_wdata\s*\(\s*(?:64'd0|0)\s*\)", inst))


def product_violations(text: str, rtl_mode: bool = False) -> list[str]:
    """Return human-readable violations (empty ⇒ product-OK)."""
    v: list[str] = []
    if rtl_mode:
        t = strip_comments(text)
        if "module plex_chrome" not in t:
            return ["not a plex_chrome module"]
        if not re.search(r"list_a\s*\[\s*0\s*\]\s*=\s*BOOT_DEMO_CMD", t):
            # Only required if BOOT_DEMO exists
            if re.search(r"BOOT_DEMO", t):
                v.append("BOOT_DEMO must preload list_a[0]=BOOT_DEMO_CMD "
                         "(live_bank=0 reads list_a; list_b-only was c74c NO-DATA)")
        if re.search(r"list_b\s*\[\s*0\s*\]\s*=\s*BOOT_DEMO_CMD", t) and not re.search(
            r"list_a\s*\[\s*0\s*\]\s*=\s*BOOT_DEMO_CMD", t
        ):
            v.append("BOOT_DEMO fills list_b only — invisible at live_bank=0")
        # Hit mux may index: live_bank ? list_b[ci] : list_a[ci]
        if not re.search(r"live_bank\s*\?\s*list_b(?:\s*\[[^\]]+\])?\s*:\s*list_a", t):
            v.append("missing hit mux live_bank ? list_b : list_a")
        return v

    insts = plex_instances(text)
    if not insts:
        # Allow non-instance fragments only if they still show the ports
        if ".list_we" in text:
            # synthesize fake instance body
            insts = [text]
        else:
            return ["no plex_chrome instance and no .list_we ports"]
    for i, inst in enumerate(insts):
        if list_we_tied_off(inst):
            v.append(f"inst{i}: .list_we(1'b0) — dead write / RAM elide (c74c6863)")
        if list_we_tied_off(inst) and list_wdata_const0(inst):
            v.append(f"inst{i}: list_we+list_wdata both const0 — NO-DATA pattern")
    return v


def run_subject(path: Path) -> int:
    text = path.read_text()
    rtl_mode = path.name.endswith(".sv") and "module plex_chrome" in text
    viol = product_violations(text, rtl_mode=rtl_mode)
    if viol:
        for x in viol:
            print(f"FAIL {path}: {x}", file=sys.stderr)
        print(f"SUBJECT_REJECT {path}", file=sys.stderr)
        return 1
    print(f"SUBJECT_OK {path}")
    return 0


def run_full() -> int:
    fails = 0

    def note_fail(msg: str) -> None:
        nonlocal fails
        fails += 1
        print(f"FAIL: {msg}", file=sys.stderr)

    def note_ok(msg: str) -> None:
        print(f"OK: {msg}")

    # --- RED fixture must violate ---
    if not BAD.is_file():
        note_fail(f"missing {BAD}")
    else:
        viol = product_violations(BAD.read_text())
        if not viol:
            note_fail("BAD fixture no longer violates product rules — gate vacuous")
        else:
            note_ok(f"BAD fixture rejected ({len(viol)} violation(s))")
            for x in viol:
                print(f"  RED-detail: {x}")

    # --- GREEN fixture must pass ---
    if not GOOD.is_file():
        note_fail(f"missing {GOOD}")
    else:
        viol = product_violations(GOOD.read_text())
        if viol:
            note_fail("GOOD fixture unexpectedly violates: " + "; ".join(viol))
        else:
            note_ok("GOOD fixture product-OK")

    # --- RTL bank polarity (our tree) ---
    if not RTL.is_file():
        note_fail(f"missing {RTL}")
    else:
        viol = product_violations(RTL.read_text(), rtl_mode=True)
        if viol:
            note_fail("RTL: " + "; ".join(viol))
        else:
            note_ok("RTL BOOT_DEMO list_a polarity OK")

    # --- Live sys_top in THIS tree only (optional instance) ---
    if SYS_TOP.is_file():
        text = SYS_TOP.read_text()
        if "plex_chrome" in text:
            viol = product_violations(text)
            if viol:
                note_fail("sys_top.v: " + "; ".join(viol))
            else:
                note_ok("sys_top.v plex_chrome write path OK")
        else:
            note_ok("sys_top.v: no plex_chrome yet (wire at next fit via GOOD fixture)")

    # Mutation: empty subject must not pass product_violations as empty insts with list_we
    if product_violations("// no chrome\n") == []:
        note_fail("empty text produced zero violations — gate vacuous")
    else:
        note_ok("empty inspection set is not a silent PASS")

    if fails:
        print(f"test_plex_chrome_write_path_static: {fails} FAIL(s)", file=sys.stderr)
        return 1
    print("test_plex_chrome_write_path_static: PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--subject",
        type=Path,
        help="Score one file: exit 1 if product violations (RED), 0 if OK (GREEN)",
    )
    args = ap.parse_args()
    if args.subject:
        return run_subject(args.subject.resolve())
    return run_full()


if __name__ == "__main__":
    sys.exit(main())
