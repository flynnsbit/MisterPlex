#!/usr/bin/env python3
"""Forbid preprocessor macros from acting as topology switches in product RTL.

WHY THIS EXISTS
---------------
`DECODE_REAL_INTRA=1` once gained 3 modules and DELETED 14 real ones - all of
inter/MC/DPB/deblock. Each configuration held half a decoder and every unit test
passed throughout, because the tests only ever exercised whichever half was
compiled. The topology is now fixed by ruling:

    stream_path -> h264_decode_core is THE product decoder
    h264_decode_top is a leaf sub-engine inside the core
    decode_stub is a retired diagnostic painter

A macro must never again decide which modules exist. This gate enforces that
structurally rather than by convention.

WHAT IT CHECKS
--------------
1. No module instantiation in product RTL sits inside `ifdef / `ifndef.
   Measured as zero at the time this gate was written, so it is a lock on a
   clean state, not an aspiration.
2. `DECODE_REAL_INTRA` is never TESTED. It survives only as a dead `define`
   (stream_path.sv:4-5) and is propagated by the QSF macro injection, so it
   could be silently re-armed by adding a single `ifdef.

"Product RTL" means files actually listed in files.qip. Bench-only sources such
as h264_decode_skeleton.sv are excluded, because they are not compiled into the
product project at all.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = ROOT / "fpga/Plex_MiSTer/rtl"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"

RETIRED_TOPOLOGY_MACROS = ("DECODE_REAL_INTRA",)

# Macro-gated instantiations that are legitimate CONFIGURATION choices rather
# than decoder-topology switches. Exact-match enforced in both directions: a new
# macro-gated instantiation fails as UNDECLARED, and one that has since been
# removed fails as STALE until the entry is deleted. Keyed "file:module".
ALLOWED_MACRO_INSTANCES = {
    "present_core.sv:ddr_frame_store":
        "DDR_FRAME_STORE selects the DDR frame-store backend. Memory backend "
        "choice, not decoder topology: both arms present the same frame store "
        "role to present_core, and neither adds or removes decoder modules.",
    "present_core.sv:frame_store":
        "DDR_FRAME_STORE `else arm - the SDRAM frame-store backend. Same "
        "justification as ddr_frame_store.",
}

COND_OPEN = re.compile(r"^\s*`(ifdef|ifndef)\s+(\w+)")
COND_ELSE = re.compile(r"^\s*`(else|elsif)\b")
COND_CLOSE = re.compile(r"^\s*`endif\b")
DEFINE_OF = re.compile(r"^\s*`define\s+(\w+)\b")
# Multi-line aware: the product core is instantiated as
#     h264_decode_core #(
#         .PARAM(x)
#     ) product_decode_core (
# so a line-anchored pattern misses the single most important instantiation in
# the tree. Allow newlines between the module name, the parameter block and the
# instance name.
INSTANCE = re.compile(
    r"^[ \t]*([A-Za-z_]\w*)[ \t\r\n]*"
    r"(?:#[ \t\r\n]*\((?:[^()]|\([^()]*\))*\)[ \t\r\n]*)?"
    r"([A-Za-z_]\w*)[ \t\r\n]*\(",
    re.M,
)
MODULE_DECL = re.compile(r"^\s*module\s+([A-Za-z_]\w*)", re.M)
# Any use of the macro that is not its own definition.
MACRO_TEST = re.compile(r"`(?:ifdef|ifndef|elsif)\s+(\w+)|`(\w+)")


def fail(msg: str) -> None:
    print(f"MACRO_TOPOLOGY_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def product_files() -> list[Path]:
    if not QIP.exists():
        fail(f"missing {QIP.relative_to(ROOT)}")
    qip = QIP.read_text(encoding="utf-8")
    out = []
    for p in sorted(RTL_DIR.glob("*.sv")):
        if p.name in qip:
            out.append(p)
    if not out:
        fail("no product RTL files resolved from files.qip")
    return out


def known_modules() -> set[str]:
    joined = "\n".join(
        strip_comments(p.read_text(encoding="utf-8")) for p in RTL_DIR.glob("*.sv")
    )
    return set(MODULE_DECL.findall(joined))


def main() -> int:
    files = product_files()
    mods = known_modules()
    violations: list[str] = []
    retired_uses: list[str] = []
    measured_macro_instances: set[str] = set()

    for path in files:
        text = strip_comments(path.read_text(encoding="utf-8"))
        lines = text.splitlines()
        stack: list[str] = []
        line_stack: dict[int, list[str]] = {}
        for lineno, line in enumerate(lines, 1):
            m = COND_OPEN.match(line)
            if m:
                macro = m.group(2)
                stack.append(macro)
                # `ifndef M / `define M is the default-value idiom, not a
                # topology decision. Anything else that TESTS a retired macro is.
                nxt = lines[lineno] if lineno < len(lines) else ""
                is_default_guard = (
                    m.group(1) == "ifndef"
                    and (DEFINE_OF.match(nxt).group(1) if DEFINE_OF.match(nxt) else None)
                    == macro
                )
                if macro in RETIRED_TOPOLOGY_MACROS and not is_default_guard:
                    retired_uses.append(
                        f"{path.name}:{lineno}: `{m.group(1)} {macro}"
                    )
                continue
            if COND_CLOSE.match(line):
                if stack:
                    stack.pop()
                continue
            if COND_ELSE.match(line):
                continue
            line_stack[lineno] = list(stack)

        # Second pass: find instantiations across line breaks and look up the
        # conditional stack that was active where each one started.
        for inst in INSTANCE.finditer(text):
            if inst.group(1) not in mods or inst.group(1) == inst.group(2):
                continue
            lineno = text.count("\n", 0, inst.start()) + 1
            active = line_stack.get(lineno)
            if not active:
                continue
            key = f"{path.name}:{inst.group(1)}"
            measured_macro_instances.add(key)
            if key not in ALLOWED_MACRO_INSTANCES:
                violations.append(
                    f"{path.name}:{lineno}: {inst.group(1)} {inst.group(2)} "
                    f"is instantiated under `{'/'.join(active)}"
                )

    stale = sorted(set(ALLOWED_MACRO_INSTANCES) - measured_macro_instances)
    for s in stale:
        print(
            f"STALE_ALLOWED_MACRO_INSTANCE {s} is no longer macro-gated; "
            "delete it from ALLOWED_MACRO_INSTANCES in this script",
            file=sys.stderr,
        )
    for v in violations:
        print(f"UNDECLARED_MACRO_GATED_INSTANTIATION {v}", file=sys.stderr)
    for r in retired_uses:
        print(
            f"RETIRED_TOPOLOGY_MACRO_TESTED {r} - this macro is retired by ruling; "
            "it must never decide topology again",
            file=sys.stderr,
        )

    if violations or retired_uses or stale:
        fail(
            "a preprocessor macro is deciding product decoder topology; "
            "see docs/decode-stub-retirement.md for why that is forbidden"
        )

    print(
        "MACRO_TOPOLOGY_OK "
        f"product_rtl_files={len(files)} "
        f"macro_gated_instantiations={len(measured_macro_instances)} "
        f"declared_config_switches={len(ALLOWED_MACRO_INSTANCES)} "
        f"undeclared=0 retired_macros_tested=0 "
        f"retired_macros={','.join(RETIRED_TOPOLOGY_MACROS)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
