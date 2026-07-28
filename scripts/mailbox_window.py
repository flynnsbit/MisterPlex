#!/usr/bin/env python3
"""Print the mailbox window the *instantiated* frame store actually answers on.

Why this exists
---------------
Every mailbox offset is relative to a doorbell placed at

    doorbell = PHYS_BASE + 2 * bank_stride - 0x1000

so changing the bank stride moves the **whole window**. Three strides exist in
this project and only one is instantiated at a time: the ``0x40000`` stride is
``ddram_frame_rd``'s bare module default and is used by no shipping layout
family; ``0x80000`` is YUV420p; ``0xC0000`` is RGB565. Each one puts the
mailbox block at a different base, and this script prints the resolved
addresses rather than repeating them here — the literals belong to
``ddr_frame_layout_params.svh`` and ``mailbox_abi_spec.hpp``, which are the
single source of truth for them.

The trap: **all of these addresses exist in the DDR address map**, and DDR keeps
whatever an older core last wrote there across a warm boot. Probing a window the
running fabric does not use therefore returns *plausible-looking magics that
never change* — which is indistinguishable, by eye, from "the mailbox is alive
but the counter is stuck".

That matters because "counter never advances" is exactly the signature people
look for when deciding whether a build is presenting frames. A probe aimed at
the wrong window manufactures that signature unconditionally, for every build,
and so cannot discriminate between two builds at all.

This script derives the live window from the RTL instead of hardcoding it, and
names the dead windows explicitly so they are not mistaken for evidence.

It reads source only. It does not contact a device and does not prove the fabric
is alive — only which addresses are worth asking.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SCOPE = (
    "Scope: derives the mailbox window the instantiated frame store answers on, "
    "from the RTL layout header and present_core.sv. Source-level only: it does "
    "not contact a device, does not prove the fabric is alive, and does not "
    "prove the design survived synthesis."
)

# offset -> (name, note)
MAILBOXES = [
    (0x000, "PLXK", "doorbell, ARM->FPGA (bank|format|seq)"),
    (0x100, "PLXS", "status, FPGA->ARM (OSD word + heartbeat)"),
    (0x108, "PLXI", "input, FPGA->ARM (playback commands)"),
    (0x110, "PLXM", "mailbox, FPGA->ARM"),
    (0x118, "PLXF", "frame-store status (underrun[15:0], debug_state[7:0])"),
    (0x120, "DIAG", "raw diagnostic word, no magic"),
    (0x128, "PLXD", "present/bank state; [31:16] = bank vsync counter"),
]

PHYS_BASE_DEFAULT = 0x30000000


def parse_layout(project: Path) -> dict[str, int]:
    header = project / "rtl" / "ddr_frame_layout_params.svh"
    if not header.is_file():
        raise SystemExit(f"FAIL layout header not found: {header}")
    consts: dict[str, int] = {}
    # The radix MUST come from the literal's own base tag, never from whether the
    # digits happen to look decimal: 32'h0008_0000 is all-digits and reading it as
    # decimal silently yields 0x13880 instead of 0x80000.
    bases = {"h": 16, "d": 10, "o": 8, "b": 2}
    for line in header.read_text(errors="replace").splitlines():
        m = re.match(
            r"\s*localparam\s+int\s+(\w+)\s*=\s*"
            r"(?:\d*'\s*[sS]?([hdobHDOB]))?\s*([0-9a-fA-F_]+)\s*;",
            line,
        )
        if not m:
            continue
        name, tag, raw = m.group(1), m.group(2), m.group(3).replace("_", "")
        base = bases[tag.lower()] if tag else 10
        try:
            consts[name] = int(raw, base)
        except ValueError:
            continue
    return consts


def instantiated_family(project: Path) -> str:
    """Which *_BANK_STRIDE does present_core.sv hand to the frame store?"""
    core = project / "rtl" / "present_core.sv"
    if not core.is_file():
        raise SystemExit(f"FAIL present_core.sv not found: {core}")
    text = core.read_text(errors="replace")
    families = set(re.findall(r"DDR_FRAME_(\w+?)_BANK_STRIDE", text))
    families |= set(re.findall(r"DDR_FRAME_(\w+?)_DOORBELL_PHYS", text))
    if len(families) != 1:
        raise SystemExit(
            "FAIL could not determine a single instantiated layout family from "
            f"present_core.sv (found {sorted(families) or 'none'}); refusing to "
            "guess, because guessing here produces a confidently wrong address"
        )
    return families.pop()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=SCOPE)
    ap.add_argument("--project", default=Path("fpga/Plex_MiSTer"), type=Path)
    ap.add_argument(
        "--devmem", action="store_true", help="emit devmem commands for the live window"
    )
    args = ap.parse_args(argv)

    if not args.project.is_dir():
        print(f"FAIL project directory not found: {args.project}")
        return 2

    print(SCOPE)
    consts = parse_layout(args.project)
    family = instantiated_family(args.project)

    stride = consts.get(f"DDR_FRAME_{family}_BANK_STRIDE")
    doorbell = consts.get(f"DDR_FRAME_{family}_DOORBELL_PHYS")
    if stride is None or doorbell is None:
        print(f"FAIL layout header has no BANK_STRIDE/DOORBELL_PHYS for {family}")
        return 1

    derived = PHYS_BASE_DEFAULT + 2 * stride - 0x1000
    print(f"\ninstantiated layout family : {family}")
    print(f"bank stride                : 0x{stride:08X}")
    print(f"doorbell (header)          : 0x{doorbell:08X}")
    print(f"doorbell (PHYS+2*stride-4K): 0x{derived:08X}")
    if derived != doorbell:
        print(
            f"FAIL header doorbell 0x{doorbell:08X} does not match the derivation "
            f"0x{derived:08X}; one of them is wrong and a probe would be aimed at "
            "an address the fabric does not answer on"
        )
        return 1

    print("\nLIVE window — probe these:")
    for off, name, note in MAILBOXES:
        print(f"  {name}  0x{doorbell + off:08X}   {note}")

    others = {
        "0x40000": PHYS_BASE_DEFAULT + 2 * 0x40000 - 0x1000,
        "0xC0000": PHYS_BASE_DEFAULT + 2 * 0xC0000 - 0x1000,
        "0x80000": PHYS_BASE_DEFAULT + 2 * 0x80000 - 0x1000,
    }
    dead = {s: a for s, a in others.items() if a != doorbell}
    print("\nDEAD windows — DO NOT PROBE (they answer with stale frozen magics):")
    for s, addr in sorted(dead.items()):
        tag = " (ddram_frame_rd module default, no shipping layout)" if s == "0x40000" else ""
        print(f"  stride {s:<9} base 0x{addr:08X}  e.g. PLXD 0x{addr + 0x128:08X}{tag}")
    print(
        "\nA probe aimed at a dead window returns a valid magic whose counter never\n"
        "advances. That is the same signature as a wedged present path, so such a\n"
        "probe cannot discriminate between two builds — it reads 'silent' for both."
    )

    if args.devmem:
        print("\n# live-window probe")
        for off, name, _ in MAILBOXES:
            print(f"devmem 0x{doorbell + off:08X} 32   # {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
