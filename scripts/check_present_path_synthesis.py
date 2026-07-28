#!/usr/bin/env python3
"""Synthesis-reality cross-check for the present path (present_core, ddr_frame_store).

WHY THIS EXISTS
---------------
Source-graph reachability is necessary but not sufficient. w-audit demonstrated
that `check_rtl_module_instantiations.py` returns rc=0 -- a green -- for a module
that is (a) instantiated only inside a disabled `generate if (0)` block, or
(b) not listed in files.qip and therefore not compiled into the design at all.
W-ARM independently reproduced both false greens against the present path:

    generate if (0) around Plex.sv:699   -> gate says REACHABLE   (truth: not instantiated)
    present_core.sv deleted from files.qip -> gate says REACHABLE (truth: not compiled)

This gate closes those two holes for the present path specifically, and adds the
third thing the graph cannot know: whether the `ifdef` that selects between
ddr_frame_store and frame_store is actually defined for the Quartus build.

WHAT THIS LITERALLY CHECKS
--------------------------
For each present-path module:
  1. its .sv file is listed in files.qip (else it is not in the design)
  2. its instantiation site is at generate-nesting depth 0, i.e. not inside any
     generate block that could be disabled
  3. every `ifdef guarding the instantiation names a macro that is defined via
     VERILOG_MACRO in Plex.qsf

WHAT THIS DOES NOT COVER
------------------------
  - It is still source-level. `make post-fit-hierarchy` on a fit report bound to
    a known RBF md5 remains the only real oracle for what is in a bitstream.
  - It does not evaluate generate conditions. Depth 0 is a sufficient condition
    for "not in a disabled generate", not a general evaluator: an instantiation
    at depth > 0 inside a genuinely enabled block will be reported, and must be
    adjudicated by hand.
  - It says nothing about reachability. Run the reachability checker in BOTH
    directions (trunk: --root emu --require <mod>; subtree: --root <parent>
    --require <mod>) as well. A subtree proof without a trunk proof is vacuous.

Exit: 0 pass, 1 fail, 77 unscored.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "fpga/Plex_MiSTer"
QIP = FPGA / "files.qip"
QSF = FPGA / "Plex.qsf"

# module -> (file containing its instantiation, file declaring the module)
PRESENT_PATH = {
    "present_core": (FPGA / "Plex.sv", FPGA / "rtl/present_core.sv"),
    "ddr_frame_store": (FPGA / "rtl/present_core.sv", FPGA / "rtl/ddr_frame_store.sv"),
}


def defined_macros(qsf_text: str) -> set[str]:
    out = set()
    for m in re.finditer(r'VERILOG_MACRO\s+"([^"=]+)(?:=[^"]*)?"', qsf_text):
        out.add(m.group(1).strip())
    return out


def find_instantiation(text: str, module: str) -> int | None:
    """1-based line of `<module> #(` or `<module> <inst> (`, skipping comments."""
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        if re.match(rf"{re.escape(module)}\s*#\s*\(", s):
            return i
        if re.match(rf"{re.escape(module)}\s+[A-Za-z_\\][\w$]*\s*\(", s):
            return i
    return None


def site_context(text: str, target_line: int) -> tuple[int, list[str]]:
    """Return (generate nesting depth, active `ifdef stack) at target_line."""
    depth = 0
    stack: list[str] = []
    for i, line in enumerate(text.splitlines(), 1):
        if i >= target_line:
            break
        s = line.strip()
        if s.startswith("//"):
            continue
        m = re.match(r"`(ifdef|ifndef|else|elsif|endif)\b\s*(\S*)", s)
        if m:
            kind, name = m.group(1), m.group(2)
            if kind in ("ifdef", "ifndef"):
                stack.append(f"{kind}:{name}")
            elif kind == "endif":
                if stack:
                    stack.pop()
            elif kind in ("else", "elsif") and stack:
                stack[-1] = "else-of:" + stack[-1].split(":", 1)[1]
        if re.search(r"\bendgenerate\b", s):
            depth = max(0, depth - 1)
        elif re.search(r"\bgenerate\b", s):
            depth += 1
    return depth, stack


def grade(qip_text: str, qsf_text: str, sources: dict[Path, str]) -> tuple[int, list[str]]:
    macros = defined_macros(qsf_text)
    failures: list[str] = []
    checks = 0

    for module, (inst_file, decl_file) in PRESENT_PATH.items():
        # 1. in files.qip
        checks += 1
        rel = decl_file.relative_to(FPGA).as_posix()
        if rel not in qip_text:
            failures.append(
                f"{module}: {rel} is NOT in files.qip, so it is not compiled into "
                "the design regardless of what the instantiation graph says"
            )
        else:
            print(f"QIP_OK {module} {rel}")

        text = sources[inst_file]
        line = find_instantiation(text, module)
        checks += 1
        if line is None:
            failures.append(
                f"{module}: no instantiation found in "
                f"{inst_file.relative_to(ROOT).as_posix()}"
            )
            continue
        depth, stack = site_context(text, line)

        # 2. generate depth
        checks += 1
        if depth != 0:
            failures.append(
                f"{module}: instantiated at generate depth {depth} in "
                f"{inst_file.relative_to(ROOT).as_posix()}:{line}; a disabled "
                "generate would make the reachability graph report a false green"
            )
        else:
            print(f"GENERATE_DEPTH_OK {module} depth=0 "
                  f"{inst_file.relative_to(ROOT).as_posix()}:{line}")

        # 3. governing ifdefs are defined for the Quartus build
        checks += 1
        undefined = []
        for entry in stack:
            kind, _, name = entry.partition(":")
            if kind == "ifdef" and name not in macros:
                undefined.append(name)
            if kind == "ifndef" and name in macros:
                undefined.append(f"!{name}")
            if kind == "else-of" and name in macros:
                undefined.append(f"else-of-{name}")
        if undefined:
            failures.append(
                f"{module}: instantiation is guarded by {stack} but "
                f"{undefined} is not satisfied by Plex.qsf VERILOG_MACRO settings, "
                "so this branch is not compiled"
            )
        else:
            print(f"IFDEF_OK {module} guards={stack or 'none'} "
                  f"(qsf macros satisfy all)")

    return checks, failures


def load_sources() -> dict[Path, str]:
    out = {}
    for _, (inst_file, _) in PRESENT_PATH.items():
        out[inst_file] = inst_file.read_text()
    return out


def run() -> int:
    for path in (QIP, QSF):
        if not path.is_file():
            print(f"SKIP-NOT-PASS check_present_path_synthesis: missing {path}")
            return 77
    for _, (inst_file, decl_file) in PRESENT_PATH.items():
        for path in (inst_file, decl_file):
            if not path.is_file():
                print(f"SKIP-NOT-PASS check_present_path_synthesis: missing {path}")
                return 77

    print(f"Scope: {len(PRESENT_PATH)} present-path modules x 4 checks "
          f"(files.qip membership, instantiation found, generate depth, ifdef macros)")
    checks, failures = grade(QIP.read_text(), QSF.read_text(), load_sources())
    if failures:
        for f in failures:
            print(f"FAIL {f}", file=sys.stderr)
        print(f"RESULT FAIL present-path synthesis cross-check "
              f"checks={checks} failures={len(failures)}")
        return 1
    print(f"RESULT PASS present-path synthesis cross-check checks={checks} failures=0")
    print("NOTE necessary, not sufficient: pair with reachability in BOTH directions "
          "and with make post-fit-hierarchy on a fit report bound to a known RBF md5")
    return 0


def self_test() -> int:
    """Ship the red for every check, using w-audit's mutations in memory."""
    print("Scope: 1 must-pass baseline + 4 must-fail mutations "
          "(qip removal, disabled generate, undefined ifdef, missing instantiation)")
    qip = QIP.read_text()
    qsf = QSF.read_text()
    src = load_sources()
    failures = 0

    checks, fails = grade(qip, qsf, src)
    if fails:
        print(f"FAIL baseline should pass but reported {fails}")
        failures += 1
    else:
        print(f"BASELINE OK checks={checks}")

    # M3: file absent from files.qip (w-audit's worst case)
    mutated_qip = "\n".join(l for l in qip.splitlines() if "present_core.sv" not in l)
    _, f2 = grade(mutated_qip, qsf, src)
    if any("files.qip" in x for x in f2):
        print("RED OK missing files.qip entry is caught")
    else:
        print("FAIL missing files.qip entry was NOT caught")
        failures += 1

    # M2: instantiation wrapped in a generate block
    inst_file = FPGA / "Plex.sv"
    text = src[inst_file]
    line = find_instantiation(text, "present_core")
    lines = text.splitlines()
    lines.insert(line - 1, "generate if (0) begin : dead_present")
    mutated_src = dict(src)
    mutated_src[inst_file] = "\n".join(lines)
    _, f3 = grade(qip, qsf, mutated_src)
    if any("generate depth" in x for x in f3):
        print("RED OK disabled generate block is caught")
    else:
        print("FAIL disabled generate block was NOT caught")
        failures += 1

    # ifdef macro not defined for the Quartus build
    mutated_qsf = qsf.replace('VERILOG_MACRO "DDR_FRAME_STORE=1"',
                              'VERILOG_MACRO "DDR_FRAME_STORE_DISABLED=1"')
    if mutated_qsf == qsf:
        print("FAIL could not locate the DDR_FRAME_STORE macro to mutate")
        failures += 1
    else:
        _, f4 = grade(qip, mutated_qsf, src)
        if any("VERILOG_MACRO" in x for x in f4):
            print("RED OK undefined guarding macro is caught")
        else:
            print("FAIL undefined guarding macro was NOT caught")
            failures += 1

    # instantiation removed entirely
    mutated_src2 = dict(src)
    mutated_src2[inst_file] = text.replace("present_core #(", "present_core_RENAMED #(", 1)
    _, f5 = grade(qip, qsf, mutated_src2)
    if any("no instantiation found" in x for x in f5):
        print("RED OK removed instantiation is caught")
    else:
        print("FAIL removed instantiation was NOT caught")
        failures += 1

    if failures:
        print(f"RESULT FAIL present-path synthesis self-test failures={failures}")
        return 1
    print("RESULT PASS present-path synthesis self-test: 1 green + 4 reds")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    return self_test() if args.self_test else run()


if __name__ == "__main__":
    sys.exit(main())
