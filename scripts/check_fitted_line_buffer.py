#!/usr/bin/env python3
"""Prove the fitted ddr_frame_store line buffer is the one the source describes.

WHY THIS EXISTS
---------------
The parent identified a third product-absence failure mode that no source-level
tool can see:

  1. file never listed in files.qip          -> detectable from the file list
  2. compiled but never instantiated         -> detectable from the source graph
  3. instantiated, elaborated, then OPTIMIZED AWAY as dead logic
                                             -> detectable ONLY by real synthesis

`check_present_path_compiled.py` covers modes 1 and 2 for the present path and
says so in its banner. This gate is the mode-3 instrument for the present path,
and it goes one step further than "is the module present": it checks that the
line buffer inside it is the SIZE the source parameters imply.

That matters because the idle-logo left-edge artifact is a line-prefetch
underrun. The prefetch depth is `LINE_COUNT`, selected by a `FRAME_LINES_*`
VERILOG_MACRO in Plex.qsf. If the macro in the .qsf and the depth in the
silicon ever disagree, every conclusion drawn about the artifact is a true
number about the wrong thing.

WHAT THIS LITERALLY COMPARES
----------------------------
predicted block memory bits
    = LINE_SLOTS * (LUMA_LINE_QWORDS + 2 * CHROMA_LINE_QWORDS) * 64
    where LINE_SLOTS = 2 * LINE_COUNT           (ddr_frame_store.sv)
          LINE_COUNT comes from the FRAME_LINES_* macro set in Plex.qsf
          the qword counts come from ddr_frame_layout_params.svh
against
    the "Block Memory Bits" cell of the ddr_frame_store row in a Quartus
    entity-hierarchy report (Plex.fit.rpt post-fit, or Plex.map.rpt pre-fit).

Every input is read from a file. Nothing is restated as a literal, so editing
the geometry header or the .qsf moves BOTH sides and the gate stays honest.

WHAT THIS DOES NOT COVER
------------------------
  * It proves the buffer has the expected *capacity*. It does not prove the
    refill scheduler keeps up, and it says nothing about whether the artifact
    is present. Capacity is a necessary input to that argument, not the answer.
  * A report is only evidence about the bitstream built from it. Pass
    --expect-rbf-md5 to bind the report to a specific RBF; without it the gate
    prints UNBOUND and the result may describe a build nobody is running.
  * It assumes the three per-slot RAMs are luma + U + V, which it verifies
    structurally in ddr_frame_store.sv rather than assuming.

Exit: 0 pass, 1 fail, 2 refusal (Scope: 0), 77 unscored (no report).
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "fpga/Plex_MiSTer"
QSF = FPGA / "Plex.qsf"
STORE_SV = FPGA / "rtl/ddr_frame_store.sv"
PRESENT_SV = FPGA / "rtl/present_core.sv"
PARAMS_SVH = FPGA / "rtl/ddr_frame_layout_params.svh"

TARGET_MODULE = "ddr_frame_store"
BITS_COL = "Block Memory Bits"
NODE_COL = "Compilation Hierarchy Node"
FULL_COL = "Full Hierarchy Name"


class Refusal(Exception):
    """Raised when an input the gate depends on cannot be read."""


def _read(path: Path) -> str:
    if not path.exists():
        raise Refusal(f"required source not found: {path}")
    return path.read_text(errors="ignore")


def line_count_from_qsf(qsf_text: str, present_text: str) -> tuple[int, str]:
    """Resolve FRAME_LINE_COUNT the way Quartus would: macro in .qsf, ladder in RTL."""
    macros = set(
        re.findall(r'VERILOG_MACRO\s+"(FRAME_LINES_\w+)=1"', _uncommented(qsf_text))
    )
    # The `ifdef ladder in present_core.sv is the authority for macro -> value.
    ladder = re.findall(
        r"`(?:ifdef|elsif)\s+(FRAME_LINES_\w+)\s*\n\s*parameter int FRAME_LINE_COUNT = (\d+)",
        present_text,
    )
    default = re.search(
        r"`else\s*\n\s*parameter int FRAME_LINE_COUNT = (\d+)", present_text
    )
    if not ladder:
        raise Refusal("no FRAME_LINES_* ladder found in present_core.sv")
    for macro, value in ladder:  # first branch wins, as `ifdef/`elsif does
        if macro in macros:
            return int(value), macro
    if not default:
        raise Refusal("FRAME_LINES ladder has no `else default")
    return int(default.group(1)), "<default, no FRAME_LINES_* macro in .qsf>"


def _uncommented(qsf_text: str) -> str:
    return "\n".join(l for l in qsf_text.splitlines() if not l.lstrip().startswith("#"))


def slots_per_line_count(store_text: str) -> int:
    m = re.search(
        r"localparam int LINE_SLOTS\s*=\s*LINE_COUNT\s*\*\s*(\d+)\s*;", store_text
    )
    if not m:
        raise Refusal("LINE_SLOTS = LINE_COUNT * N not found in ddr_frame_store.sv")
    return int(m.group(1))


def qwords_from_params(params_text: str) -> tuple[int, int]:
    def grab(name: str) -> int:
        m = re.search(rf"localparam int {name}\s*=\s*(\d+)\s*;", params_text)
        if not m:
            raise Refusal(f"{name} not found in ddr_frame_layout_params.svh")
        return int(m.group(1))

    return grab("DDR_FRAME_YUV_LUMA_LINE_QWORDS"), grab(
        "DDR_FRAME_YUV_CHROMA_LINE_QWORDS"
    )


def ram_shape(store_text: str) -> tuple[int, int]:
    """Return (number of per-slot RAM data buses, their width in bits)."""
    buses = re.findall(r"wire \[(\d+):0\] ([yuv])_q \[0:LINE_SLOTS-1\];", store_text)
    if not buses:
        raise Refusal("per-slot y_q/u_q/v_q line buffers not found")
    widths = {int(hi) + 1 for hi, _ in buses}
    if len(widths) != 1:
        raise Refusal(f"per-slot line buffers have mixed widths: {sorted(widths)}")
    return len(buses), widths.pop()


def parse_entity_bits(report: Path, module: str):
    """Return (rows_scanned, {full_hierarchy_path: block_memory_bits}) for `module`.

    Two defects w-audit found in the fleet's hierarchy tooling apply here and are
    handled explicitly:

    * UNBOUNDED TABLE. A Quartus fit report contains ~15 tables after the entity
      table, and an entity-shaped row in a later one (e.g. "Fitter RAM Summary")
      is otherwise absorbed. Measured on fb4bad84: splicing one poisoned row
      moved the scope from 827 to 828 rows and the poisoned value won. The table
      is therefore terminated at the first row whose leading cell is not a
      `|node|` cell -- verified to be exactly the table end on the real reports.
    * ANCESTOR HIDING. Reporting a bare node name, or only a direct parent, lets
      an ancestor such as decode_stub disappear from the evidence. This keys on
      the report's own "Full Hierarchy Name" column, so the entire chain is
      always carried, and refuses the row if that column is absent.
    """
    rows = 0
    found = {}
    node_i = bits_i = full_i = None
    started = False
    for raw in report.read_text(errors="ignore").splitlines():
        if not raw.startswith(";"):
            continue
        cells = [c.strip() for c in raw.split(";")]
        if node_i is None:
            if NODE_COL in cells and BITS_COL in cells:
                node_i, bits_i = cells.index(NODE_COL), cells.index(BITS_COL)
                full_i = cells.index(FULL_COL) if FULL_COL in cells else None
            continue
        short = len(cells) <= max(i for i in (node_i, bits_i) if i is not None)
        node = None if short else cells[node_i]
        m = None if short else re.match(r"^\|([A-Za-z_][\w$]*)(?::(.*))?\|?$", node)
        if m is None:
            # End of the entity table. A fit report holds ~15 further tables and
            # an entity-shaped row in any of them must not be scanned. Rows that
            # are merely too short also terminate it: they are prose or headers
            # belonging to the next table, never table content -- verified on
            # the real reports, where every in-table row leads with |node|.
            if started:
                break
            continue
        started = True
        rows += 1
        if m.group(1) != module:
            continue
        bits = cells[bits_i]
        if not re.fullmatch(r"\d+", bits):
            continue
        if full_i is None or len(cells) <= full_i or not cells[full_i].startswith("|"):
            found[f"<NO FULL HIERARCHY COLUMN> {node}"] = int(bits)
            continue
        found[cells[full_i]] = int(bits)
    return rows, found


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Compare the fitted ddr_frame_store line-buffer size against "
        "the size the RTL parameters and Plex.qsf macros predict."
    )
    ap.add_argument("report", nargs="?", help="Plex.fit.rpt or Plex.map.rpt")
    ap.add_argument(
        "--expect-rbf-md5",
        metavar="MD5",
        help="bind the report to an RBF: the sibling Plex.rbf must have this md5 "
        "(full or leading prefix). Without it the result is UNBOUND.",
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--forbid-ancestor",
        action="append",
        default=[],
        metavar="MODULE",
        help="fail if MODULE appears ANYWHERE in the module's full hierarchy "
        "chain. w-audit showed that direct-parent checks miss nested masking, "
        "so this walks the whole chain.",
    )
    ap.add_argument(
        "--require-ancestor",
        action="append",
        default=[],
        metavar="MODULE",
        help="fail unless MODULE appears in the full hierarchy chain (trunk proof).",
    )
    ap.add_argument(
        "--compare",
        metavar="OTHER_REPORT",
        help="A/B a second entity report against `report`. REFUSES if the two "
        "reports bind to the same RBF md5, because a comparison that does not "
        "vary its independent variable proves fitter determinism and nothing "
        "else.",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.report:
        ap.error("a Quartus entity report is required (or --self-test)")
    if args.compare:
        return compare_reports(Path(args.report), Path(args.compare))

    try:
        predicted, detail = predict_bits()
    except Refusal as exc:
        print("Scope: 0 -- cannot derive the expected size")
        print(f"REFUSED: {exc}")
        return 2

    report = Path(args.report)
    if not report.exists():
        print("Scope: 0 -- no Quartus entity report")
        print(f"SKIP: report not found: {report}")
        return 77

    rows, found = parse_entity_bits(report, TARGET_MODULE)
    print(f"Scope: {rows} entity rows in {report}")
    print(f"       {len(found)} {TARGET_MODULE} instance(s)")
    for k, v in detail.items():
        print(f"       {k} = {v}")
    print(f"       predicted Block Memory Bits = {predicted}")

    rc = 0

    # Binding: a report proves nothing about a bitstream nobody is running.
    rbf = report.parent / "Plex.rbf"
    if args.expect_rbf_md5:
        if not rbf.exists():
            print(f"UNBOUND: no sibling Plex.rbf beside {report}")
            rc = 1
        else:
            got = hashlib.md5(rbf.read_bytes()).hexdigest()
            if not got.startswith(args.expect_rbf_md5.lower()):
                print(f"BINDING_FAIL sibling Plex.rbf md5={got[:8]} "
                      f"expected={args.expect_rbf_md5}")
                rc = 1
            else:
                print(f"BOUND report -> Plex.rbf md5={got[:8]}")
    else:
        # Cannot evaluate. Printing "UNBOUND" into a log while returning 0 is
        # exactly the print/exit divergence the parent banned: the text says
        # "do not cite me" and the exit code says "green", and every wrapper,
        # Makefile and CI step reads the exit code. Return 77 -- "could not
        # evaluate" -- and do NOT print a verdict line, so no caller can grep
        # LINE_BUFFER_OK out of an unbound run.
        print("UNBOUND: no --expect-rbf-md5 given; this report may describe a "
              "build that is not deployed anywhere")
        print("SKIP-NOT-PASS cannot evaluate without an RBF binding", file=sys.stderr)
        return 77

    if rows == 0:
        print("REFUSED: Scope: 0 entity rows parsed -- a PASS cannot be claimed")
        return 2
    if not found:
        print(f"ABSENT {TARGET_MODULE} -- no row in the entity hierarchy. This is "
              "the optimize-away signature (mode 3) or the module was never built.")
        print("LINE_BUFFER_FAIL")
        return 1

    for path, bits in sorted(found.items()):
        chain = [seg.split(":")[0] for seg in path.strip("|").split("|")]
        if path.startswith("<NO FULL HIERARCHY COLUMN>"):
            print(f"REFUSED: the report has no '{FULL_COL}' column, so an ancestor "
                  "could be hidden. Evidence cited from a bare node name is not "
                  "acceptable after w-audit's nested-masking finding.")
            return 2
        for bad in args.forbid_ancestor:
            if bad in chain[:-1]:
                print(f"MASKED {TARGET_MODULE} -- forbidden ancestor '{bad}' in "
                      f"chain {' -> '.join(chain)}")
                rc = 1
        for need in args.require_ancestor:
            if need not in chain[:-1]:
                print(f"MISPARENTED {TARGET_MODULE} -- required ancestor '{need}' "
                      f"absent from chain {' -> '.join(chain)}")
                rc = 1
        if bits == predicted:
            print(f"MATCH  {bits} bits  {path}")
        else:
            ratio = f"{bits / predicted:.3f}x" if predicted else "n/a"
            print(f"MISMATCH {bits} bits (predicted {predicted}, {ratio})  {path}")
            print("    The fitted line buffer is not the size the sources imply. "
                  "Either the FRAME_LINES_* macro in Plex.qsf is not the one that "
                  "built this report, or synthesis resized/removed the buffer.")
            rc = 1

    print("LINE_BUFFER_OK" if rc == 0 else "LINE_BUFFER_FAIL",
          f"predicted={predicted} instances={len(found)} rows={rows}")
    return rc


RESOURCE_COLS = [
    "Combinational ALUTs",
    "Dedicated Logic Registers",
    "Block Memory Bits",
    "M10Ks",
    "DSP Blocks",
]


def _rbf_md5(report: Path):
    rbf = report.parent / "Plex.rbf"
    if not rbf.exists():
        return None
    return hashlib.md5(rbf.read_bytes()).hexdigest()


def _parse_resources(report: Path):
    """Return {hierarchy path -> {column -> value}} keyed on the full parent chain."""
    header = None
    idx = {}
    node_i = None
    stack = {}
    out = {}
    for raw in report.read_text(errors="ignore").splitlines():
        if not raw.startswith(";"):
            continue
        cells = [c.strip() for c in raw.split(";")]
        if header is None:
            if NODE_COL in cells:
                header = cells
                node_i = cells.index(NODE_COL)
                idx = {c: cells.index(c) for c in RESOURCE_COLS if c in cells}
            continue
        if node_i is None or not idx or len(cells) <= max(idx.values()):
            continue
        m = re.match(r"^(\s*)\|([A-Za-z_][\w$]*)(?::([^|]*))?\|?$", raw.split(";")[1].rstrip())
        if not m:
            continue
        indent = len(m.group(1))
        for k in [k for k in stack if k >= indent]:
            del stack[k]
        stack[indent] = f"{m.group(2)}:{m.group(3) or ''}"
        key = "|".join(stack[k] for k in sorted(stack))
        vals = {}
        for col, i in idx.items():
            raw_val = cells[i].split("(")[0].strip()
            try:
                vals[col] = float(raw_val)
            except ValueError:
                vals[col] = None
        out[key] = vals
    return out


def compare_reports(a: Path, b: Path) -> int:
    """A/B two entity reports, refusing comparisons that do not vary anything.

    w-fit-o5 showed that four fit slots agreeing on an identical constraint file
    was read as "the constraint change is netlist-neutral". It was not evidence:
    the comparison never varied the independent variable, so it demonstrated
    fitter determinism. This mode refuses that shape of control outright.
    """
    for p in (a, b):
        if not p.exists():
            print("Scope: 0 -- report missing")
            print(f"SKIP: {p} not found")
            return 77

    md5a, md5b = _rbf_md5(a), _rbf_md5(b)
    print(f"Scope: A={a} rbf={(md5a or '<none>')[:8]}")
    print(f"       B={b} rbf={(md5b or '<none>')[:8]}")

    if md5a is None or md5b is None:
        print("REFUSED: a sibling Plex.rbf is missing, so neither side can be "
              "bound to a bitstream and the comparison is unattributable")
        return 2
    if md5a == md5b:
        print("REFUSED: VACUOUS CONTROL -- both reports bind to the SAME RBF "
              f"md5={md5a[:8]}. This measures fitter determinism, not the change "
              "you think you are testing.")
        return 2

    ra, rb = _parse_resources(a), _parse_resources(b)
    common = sorted(set(ra) & set(rb))
    print(f"       {len(ra)} vs {len(rb)} entity paths, {len(common)} common, "
          f"{len(set(ra) ^ set(rb))} present on one side only")
    if not common:
        print("REFUSED: Scope: 0 common entity paths -- nothing to compare")
        return 2

    print(f"column deltas over {len(common)} common paths (B - A):")
    changed_any = False
    for col in RESOURCE_COLS:
        moved = [
            (p, ra[p][col], rb[p][col])
            for p in common
            if ra[p].get(col) is not None
            and rb[p].get(col) is not None
            and ra[p][col] != rb[p][col]
        ]
        net = sum(y - x for _, x, y in moved)
        verdict = "IDENTICAL in every path" if not moved else (
            f"{len(moved)}/{len(common)} paths differ, net {net:+g}"
        )
        print(f"  {col:28s} {verdict}")
        if moved:
            changed_any = True
            for p, x, y in sorted(moved, key=lambda t: -abs(t[2] - t[1]))[:5]:
                print(f"      {y - x:+g}  {p[:100]}")

    if not changed_any:
        print("NOTE the two bitstreams differ but no entity-level resource does. "
              "The change is placement/routing/timing only -- read the STA "
              "report, not this one.")
    print("COMPARE_OK", f"paths={len(common)} a={md5a[:8]} b={md5b[:8]}")
    return 0


def predict_bits() -> tuple[int, dict]:
    qsf = _read(QSF)
    present = _read(PRESENT_SV)
    store = _read(STORE_SV)
    params = _read(PARAMS_SVH)

    line_count, via = line_count_from_qsf(qsf, present)
    mult = slots_per_line_count(store)
    luma_qw, chroma_qw = qwords_from_params(params)
    n_buses, width = ram_shape(store)
    if n_buses != 3:
        raise Refusal(f"expected 3 per-slot line buffers (y,u,v), found {n_buses}")

    slots = line_count * mult
    per_slot_qwords = luma_qw + 2 * chroma_qw
    bits = slots * per_slot_qwords * width
    detail = {
        "FRAME_LINE_COUNT": f"{line_count} (via {via})",
        "LINE_SLOTS": f"{slots} = LINE_COUNT * {mult}",
        "qwords per slot": f"{per_slot_qwords} = luma {luma_qw} + 2 * chroma {chroma_qw}",
        "RAM data width": f"{width} bits, {n_buses} buffers per slot",
    }
    return bits, detail


# --------------------------------------------------------------------------
# Self-test: one green and four reds. A gate that cannot be made to fail is
# not evidence, so each red mutates exactly one input and must flip the
# verdict. Sources are restored on every path, including on exception.
# --------------------------------------------------------------------------

SYNTH_REPORT = """; Fitter Resource Utilization by Entity
; Compilation Hierarchy Node ; Block Memory Bits ; M10Ks ; Full Hierarchy Name ;
; |sys_top ; 0 ; 0 ; |sys_top ;
;    |emu:emu| ; {total} ; 400 ; |sys_top|emu:emu ;
;       |present_core:present| ; {total} ; 103 ; |sys_top|emu:emu|present_core:present ;
;          |ddr_frame_store:fstore| ; {bits} ; 96 ; |sys_top|emu:emu|present_core:present|ddr_frame_store:fstore ;
"""


def _write_report(tmp: Path, bits: int) -> Path:
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(SYNTH_REPORT.format(bits=bits, total=bits + 65536))
    return tmp


def self_test() -> int:
    import io
    import contextlib

    scratch = ROOT / "build/line_buffer_selftest"
    cases = []

    def run(argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(argv)
        return rc, buf.getvalue()

    def bound(report, *extra):
        """Argv for a fixture, satisfying the SAME binding contract as production.

        The self-test fixtures are not exempt from the RBF-binding rule. When
        the rule tightened to 77-on-unbound, every fixture correctly went 77 --
        so each one gets a real sibling Plex.rbf and a real md5 rather than an
        escape hatch, because an escape hatch is how the hole comes back.
        """
        report = Path(report)
        rbf = report.parent / "Plex.rbf"
        if not rbf.exists():
            rbf.write_bytes(b"selftest-rbf:" + str(report.parent.name).encode())
        digest = hashlib.md5(rbf.read_bytes()).hexdigest()[:8]
        return [str(report), "--expect-rbf-md5", digest, *extra]

    predicted, _ = predict_bits()
    good = _write_report(scratch / "good/Plex.fit.rpt", predicted)

    rc, out = run(bound(good))
    cases.append(("green: fitted size equals predicted size", rc == 0, rc, 0))

    # RED 1: silicon carries half the buffer -- the FRAME_LINES macro that built
    # the report was not the one in Plex.qsf.
    half = _write_report(scratch / "half/Plex.fit.rpt", predicted // 2)
    rc, out = run(bound(half))
    cases.append(("red: half-size buffer must FAIL", rc == 1 and "MISMATCH" in out, rc, 1))

    # RED 2: module optimized away entirely (mode 3).
    gone = scratch / "gone/Plex.fit.rpt"
    gone.parent.mkdir(parents=True, exist_ok=True)
    gone.write_text(
        SYNTH_REPORT.format(bits=predicted, total=predicted).replace(
            "|ddr_frame_store:fstore|", "|colorbars:bars|"
        )
    )
    rc, out = run(bound(gone))
    cases.append(("red: optimized-away module must FAIL", rc == 1 and "ABSENT" in out, rc, 1))

    # RED 3: report with no entity rows must refuse, not pass.
    empty = scratch / "empty/Plex.fit.rpt"
    empty.parent.mkdir(parents=True, exist_ok=True)
    empty.write_text("; Fitter Resource Utilization by Entity\n; nothing here ;\n")
    rc, out = run(bound(empty))
    cases.append(("red: Scope 0 rows must REFUSE (2)", rc == 2, rc, 2))

    # w-audit's unbounded-table defect, reproduced against this gate and fixed.
    # Measured on the real fb4bad84 report before the fix: an entity-shaped row
    # spliced into a later table moved Scope from 827 to 828 rows and its value
    # was scored. After the fix the trailing table must be invisible.
    trailing = scratch / "trailing/Plex.fit.rpt"
    trailing.parent.mkdir(parents=True, exist_ok=True)
    trailing.write_text(
        SYNTH_REPORT.format(bits=predicted, total=predicted + 65536)
        + "; Fitter RAM Summary ;\n"
        + "; prose row ;\n"
        + "; |ddr_frame_store:fstore| ; 999999 ; 1 ; |bogus ;\n"
    )
    rc, out = run(bound(trailing))
    cases.append((
        "red: entity-shaped row in a LATER table must be excluded",
        rc == 0 and "999999" not in out and "Scope: 4 entity rows" in out,
        rc, 0))

    # w-audit's nested-masking defect: a direct-parent check misses an ancestor
    # further up. This walks the whole chain.
    masked = scratch / "masked/Plex.fit.rpt"
    masked.parent.mkdir(parents=True, exist_ok=True)
    masked.write_text(
        SYNTH_REPORT.format(bits=predicted, total=predicted).replace(
            "|sys_top|emu:emu|present_core:present|ddr_frame_store:fstore",
            "|sys_top|emu:emu|decode_stub:stub|wrapper:w|ddr_frame_store:fstore",
        )
    )
    rc, out = run(bound(masked, "--forbid-ancestor", "decode_stub"))
    cases.append(("red: NESTED forbidden ancestor must FAIL",
                  rc == 1 and "MASKED" in out, rc, 1))

    rc, out = run(bound(good, "--require-ancestor", "h264_decode_core"))
    cases.append(("red: absent required ancestor must FAIL",
                  rc == 1 and "MISPARENTED" in out, rc, 1))

    rc, out = run(bound(good, "--require-ancestor", "emu", "--require-ancestor",
                   "present_core", "--forbid-ancestor", "decode_stub"))
    cases.append(("green: real chain satisfies trunk and forbids stub", rc == 0, rc, 0))

    # A report with no Full Hierarchy column cannot prove an ancestor is absent.
    nofull = scratch / "nofull/Plex.fit.rpt"
    nofull.parent.mkdir(parents=True, exist_ok=True)
    nofull.write_text(
        SYNTH_REPORT.format(bits=predicted, total=predicted).replace(
            " ; Full Hierarchy Name ;", " ;"
        )
    )
    rc, out = run(bound(nofull))
    cases.append(("red: missing Full Hierarchy column must REFUSE (2)",
                  rc == 2, rc, 2))

    # RED 4: binding to an RBF that is not there must FAIL, not silently pass.
    rc, out = run([str(good), "--expect-rbf-md5", "deadbeef"])
    cases.append(("red: unsatisfiable RBF binding must FAIL",
                  rc == 1 and ("BINDING_FAIL" in out or "UNBOUND" in out)
                  and "LINE_BUFFER_OK" not in out, rc, 1))

    # RED 4b: THE w-audit DEFECT. With no --expect-rbf-md5 this gate printed
    # "UNBOUND" and then exited 0 with LINE_BUFFER_OK. Text said "do not cite
    # me", exit code said green, and the exit code is what every wrapper reads.
    # Cannot-evaluate must be 77, and no verdict line may be emitted at all --
    # printing UNBOUND is not a substitute for refusing to answer.
    rc, out = run([str(good)])
    cases.append(("red: unbound report must be 77, not 0",
                  rc == 77, rc, 77))
    cases.append(("red: unbound report must not print LINE_BUFFER_OK",
                  "LINE_BUFFER_OK" not in out, 0 if "LINE_BUFFER_OK" not in out else 1, 0))

    # --compare vacuity guard. w-fit-o5's exoneration of the SDC change was
    # vacuous because all four compared slots carried an IDENTICAL constraint
    # file: the control never varied the independent variable. Refuse that.
    same_a = scratch / "cmp_same_a"
    same_b = scratch / "cmp_same_b"
    for d in (same_a, same_b):
        _write_report(d / "Plex.fit.rpt", predicted)
        (d / "Plex.rbf").write_bytes(b"identical-bitstream")
    rc, out = run([str(same_a / "Plex.fit.rpt"), "--compare", str(same_b / "Plex.fit.rpt")])
    cases.append(("red: same-RBF A/B must REFUSE as vacuous (2)",
                  rc == 2 and "VACUOUS CONTROL" in out, rc, 2))

    # ... and an unbindable side must refuse too, not quietly compare.
    nobind = scratch / "cmp_nobind"
    _write_report(nobind / "Plex.fit.rpt", predicted)
    rc, out = run([str(same_a / "Plex.fit.rpt"), "--compare", str(nobind / "Plex.fit.rpt")])
    cases.append(("red: unbindable A/B side must REFUSE (2)",
                  rc == 2 and "unattributable" in out, rc, 2))

    # green: two genuinely different bitstreams compare, and a resource that
    # really moved is reported.
    diff_b = scratch / "cmp_diff_b"
    _write_report(diff_b / "Plex.fit.rpt", predicted)
    (diff_b / "Plex.rbf").write_bytes(b"a-different-bitstream")
    rc, out = run([str(same_a / "Plex.fit.rpt"), "--compare", str(diff_b / "Plex.fit.rpt")])
    cases.append(("green: differing-RBF A/B compares", rc == 0 and "COMPARE_OK" in out, rc, 0))

    # Missing report is a skip, never a pass.
    rc, out = run([str(scratch / "absent/Plex.fit.rpt")])
    cases.append(("skip: missing report must be 77", rc == 77, rc, 77))

    greens = sum(1 for n, *_ in cases if n.startswith("green"))
    reds = sum(1 for n, *_ in cases if n.startswith("red"))
    skips = sum(1 for n, *_ in cases if n.startswith("skip"))
    print(f"Scope: {len(cases)} self-test cases "
          f"({greens} green, {reds} reds, {skips} skip)")
    bad = 0
    for name, ok, got, want in cases:
        print(f"  {'PASS' if ok else 'FAIL'} {name} (rc={got}, want {want})")
        bad += 0 if ok else 1
    print("LINE_BUFFER_SELFTEST_OK" if bad == 0 else f"LINE_BUFFER_SELFTEST_FAIL {bad}")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
