#!/usr/bin/env python3
"""Trunk reachability gate: prove h264_decode_core is actually wired into emu.

w-audit broke the core-subtree gate on w-deblock-seam 7225e00 by showing that

    --root h264_decode_core --require h264_deblock_writeback_ctrl   -> rc=0
    --root emu             --require h264_decode_core               -> rc=1

can both be true: the module really is inside the core, and the core really is
dead. A subtree proof without a trunk proof is vacuous.

This gate proves the trunk, and it does so from the *Quartus* file list
(Plex.qsf + files.qip) rather than from a hand-written list, so a module whose
RTL file is not compiled into the design cannot pass: it is never handed to the
elaborator at all. That closes w-audit's third attack (tracked in git but absent
from files.qip) by construction rather than by a separate lookup.

Checks:
  1. emu elaborates, and h264_decode_core is in emu's elaborated subtree (TRUNK);
  2. every required MC/DPB/reference module is also in emu's subtree (END-TO-END);
  3. every owning RTL file is present in the Quartus file list (FILES.QIP).

Red proofs (each mutation must make the trunk claim fail, sources restored in a
finally block):
  A. cut the h264_decode_core instantiation out of stream_path;
  B. wrap that instantiation in a disabled `if (0)` generate (w-audit attack 1);
  C. drop the DPB RTL file from files.qip (w-audit attack 3).

Plus one mutation that must NOT change the verdict:

  D. rename the instance to an escaped identifier (w-audit attack 2, which makes
     the regex checker report a false failure).
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

PROJECT = ROOT / "fpga" / "Plex_MiSTer"
RTL = PROJECT / "rtl"
FILES_QIP = PROJECT / "files.qip"
BUILD = ROOT / "build" / "verilator" / "h264_decode_core_trunk_elab"

TOP = "emu"
PRODUCT_ROOT = "h264_decode_core"
CORE_ANCHOR = "h264_decode_core #("

REQUIRED = [
    "h264_inter_mc_part",
    "h264_inter_mc_16x16",
    "h264_luma_qpel_block_16x16",
    "h264_chroma_epel_block_8x8",
    "h264_dpb_one_ref",
    "h264_luma_ref_tap_addr",
    "h264_ref_clamp",
    "h264_deblock_writeback_ctrl",
]

STAGE_MIN = 14
STAGE_MAX = 32

def owning_files():
    """Map each required module to the RTL file that defines it.

    Derived at run time rather than hardcoded: a hardcoded list silently goes
    stale when a module moves file, which is exactly the failure mode this gate
    exists to catch. It also keeps literal RTL filenames out of this source, so
    test_bench_rtl_filelists.py does not mistake a files.qip assertion for a
    Verilator input list.
    """
    decl = re.compile(r"^\s*module\s+([A-Za-z_]\w*)", re.M)
    owner = {}
    for path in sorted(RTL.iterdir()):
        if path.suffix not in (".sv", ".v"):
            continue
        for mod in decl.findall(path.read_text(errors="replace")):
            owner.setdefault(mod, path.name)
    return owner


OWNER = owning_files()
# Resolved through module ownership, never spelled literally: a hardcoded RTL
# filename here would be read by test_bench_rtl_filelists.py as a Verilator
# input list, and this gate hands Verilator the Quartus list instead.
STREAM_PATH = RTL / OWNER["stream_path"]
DPB_FILE = OWNER["h264_dpb_one_ref"]


# Verilator's V3Param stage dies with an internal error on the Altera PLL vendor
# megafunctions, which would leave us with only pre-parameter AST dumps - and
# those still contain dead generate arms. Swapping the vendor PLLs for stubs lets
# parameter resolution complete, so the graph we measure is generate-pruned.
PLL_STUB = r"""
module pll(input refclk, input rst, output outclk_0, output outclk_1,
    output outclk_2, output outclk_3, output locked,
    input [63:0] reconfig_to_pll, output [63:0] reconfig_from_pll);
  assign {outclk_0, outclk_1, outclk_2, outclk_3} = 4'b0;
  assign locked = 1'b1; assign reconfig_from_pll = 64'b0;
endmodule
module pll_hdmi(input refclk, input rst, output outclk_0, output locked,
    input [63:0] reconfig_to_pll, output [63:0] reconfig_from_pll);
  assign outclk_0 = 1'b0; assign locked = 1'b1; assign reconfig_from_pll = 64'b0;
endmodule
module pll_audio(input refclk, input rst, output outclk_0, output locked,
    input [63:0] reconfig_to_pll, output [63:0] reconfig_from_pll);
  assign outclk_0 = 1'b0; assign locked = 1'b1; assign reconfig_from_pll = 64'b0;
endmodule
module pll_cfg(input mgmt_clk, input mgmt_reset, input [5:0] mgmt_address,
    input mgmt_read, output [31:0] mgmt_readdata, output mgmt_waitrequest,
    input mgmt_write, input [31:0] mgmt_writedata,
    output [63:0] reconfig_to_pll, input [63:0] reconfig_from_pll);
  assign mgmt_readdata = 32'b0; assign mgmt_waitrequest = 1'b0;
  assign reconfig_to_pll = 64'b0;
endmodule
module pll_cfg_hdmi(input mgmt_clk, input mgmt_reset, input [5:0] mgmt_address,
    input mgmt_read, output [31:0] mgmt_readdata, output mgmt_waitrequest,
    input mgmt_write, input [31:0] mgmt_writedata,
    output [63:0] reconfig_to_pll, input [63:0] reconfig_from_pll);
  assign mgmt_readdata = 32'b0; assign mgmt_waitrequest = 1'b0;
  assign reconfig_to_pll = 64'b0;
endmodule
"""


def elaborate(tag):
    """Elaborate the Quartus design list rooted at emu; return (rc, dump dir)."""
    import rtl_lint

    files, _macros = rtl_lint.discover_design()
    stub = rtl_lint.write_intel_stubs()
    pll_stub = ROOT / "build" / "trunk_elab_pll_stubs.sv"
    pll_stub.parent.mkdir(parents=True, exist_ok=True)
    pll_stub.write_text(PLL_STUB)
    files = [p for p in files if "pll" not in p.name.lower()]
    mdir = BUILD / tag
    mdir.mkdir(parents=True, exist_ok=True)
    for stale in mdir.glob("*.tree.json"):
        stale.unlink()
    ordered = sorted(
        files, key=lambda p: (rtl_lint.is_excluded(p), rtl_lint.rel(p) if p.exists() else str(p))
    )
    # verilator_define_args() shell-escapes BUILD_DATE for a shell invocation; we
    # exec without a shell, so pass the unescaped literal.
    defines = [
        a if not a.startswith("-DBUILD_DATE") else '-DBUILD_DATE="lint"'
        for a in rtl_lint.verilator_define_args()
    ]
    cmd = [
        str(ROOT / "scripts" / "run_verilator.sh"),
        "--lint-only", "--dump-tree-json",
        "--Mdir", str(mdir),
        "--top-module", TOP,
        "-Wno-fatal", "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-PINMISSING",
        "-Wno-MULTITOP", "-Wno-EOFNEWLINE", "-Wno-GENUNNAMED", "-Wno-PINNOTFOUND",
        "-Wno-MODDUP", "--error-limit", "100000",
        "-I" + str(ROOT / "build" / "rtl_lint_generated"),
        "-I" + str(PROJECT), "-I" + str(PROJECT / "sys"), "-I" + str(PROJECT / "rtl"),
        str(stub), str(pll_stub),
    ] + defines + [str(p) for p in ordered]
    log = mdir / "lint.log"
    with open(log, "w") as fh:
        rc = subprocess.call(cmd, cwd=str(ROOT), stdout=fh, stderr=subprocess.STDOUT)
    return rc, mdir, len(ordered)


def graph_from(mdir):
    """Instance graph from the richest post-elaboration, dead-code-pruned dump.

    Stage choice is load-bearing and was measured, not assumed. Wrapping the
    core instantiation in `if (1'b0)` still leaves it present at 002_cellsort,
    008_linkinc, 009_param and 010_linkdotparam; it disappears at 014_width
    (subtree 49 -> 42), which is where dead generate arms are actually removed.
    From 033_inline onward the dump carries no CELL nodes at all. So the only
    usable window is 014..032, and reading outside it produces a false pass
    (below 014) or an empty graph (above 032).
    """
    best = ({}, set(), None)
    for dump in sorted(mdir.glob("*.tree.json")):
        try:
            stage = int(dump.stem.split("_")[1])
        except (IndexError, ValueError):
            continue
        if stage < STAGE_MIN or stage > STAGE_MAX:
            continue
        try:
            with open(dump) as fh:
                tree = json.load(fh)
        except (OSError, ValueError):
            continue
        modules = {}
        cells = []

        def walk(node, owner):
            kind = node.get("type")
            if kind == "MODULE":
                modules[node.get("addr")] = node.get("origName") or node.get("name")
                owner = node.get("addr")
            elif kind == "CELL":
                cells.append((owner, node.get("modp")))
            for value in node.values():
                if isinstance(value, list):
                    for child in value:
                        if isinstance(child, dict):
                            walk(child, owner)
                elif isinstance(value, dict):
                    walk(value, owner)

        walk(tree, None)
        graph = {}
        for parent, child in cells:
            pn, cn = modules.get(parent), modules.get(child)
            if pn and cn:
                graph.setdefault(pn, set()).add(cn)
        if sum(len(v) for v in graph.values()) > sum(len(v) for v in best[0].values()):
            best = (graph, set(modules.values()), dump.name)
    return best


def subtree(graph, root):
    seen = set()
    stack = [root]
    while stack:
        for child in graph.get(stack.pop(), ()):
            if child not in seen:
                seen.add(child)
                stack.append(child)
    return seen


def emu_reach(tag):
    rc, mdir, nfiles = elaborate(tag)
    graph, modules, dump = graph_from(mdir)
    if dump is None:
        raise RuntimeError(
            "no parameter-resolved AST dump produced in %s; refusing to measure "
            "reachability on a pre-V3Param tree because dead generate arms are "
            "still present there" % mdir)
    return rc, subtree(graph, TOP), modules, nfiles, dump


def cut(text, anchor):
    start = text.index(anchor)
    line_start = text.rfind("\n", 0, start) + 1
    depth, idx, opened = 0, start, False
    while idx < len(text):
        ch = text[idx]
        if ch == "(":
            depth += 1
            opened = True
        elif ch == ")":
            depth -= 1
            if opened and depth == 0:
                end = text.index(";", idx) + 1
                break
        idx += 1
    else:
        raise RuntimeError("no end found for " + anchor)
    return text[:line_start], text[line_start:end], text[end:]


def main():
    probe = subprocess.run(
        [str(ROOT / "scripts" / "run_verilator.sh"), "--version"],
        cwd=str(ROOT), capture_output=True, text=True)
    if probe.returncode == 127:
        print("TRUNK_ELAB_REFUSED(exit=3): Verilator not found; the trunk was NOT "
              "elaborated. Refusing to report a pass.", file=sys.stderr)
        return 3
    if probe.returncode != 0:
        print("TRUNK_ELAB_ERROR: Verilator probe failed rc=%d" % probe.returncode,
              file=sys.stderr)
        return probe.returncode

    print("Scope: elaboration-aware TRUNK proof that %s is reachable from %s in the "
          "Quartus design (Plex.qsf + files.qip), plus %d required MC/DPB/reference "
          "modules end-to-end, with three mutated red proofs"
          % (PRODUCT_ROOT, TOP, len(REQUIRED)))

    qip_text = FILES_QIP.read_text()
    owner = owning_files()
    wanted = [PRODUCT_ROOT] + REQUIRED
    undefined = [m for m in wanted if m not in owner]
    if undefined:
        print("TRUNK_ELAB_FAIL: no RTL file defines: " + ", ".join(undefined),
              file=sys.stderr)
        return 1
    need_files = sorted({owner[m] for m in wanted})
    missing_qip = [f for f in need_files if f not in qip_text]
    if missing_qip:
        print("TRUNK_ELAB_FAIL: files absent from the Quartus file list (not in the "
              "design at all): " + ", ".join(missing_qip), file=sys.stderr)
        return 1
    for name in need_files:
        print("FILES_QIP_PRESENT %s" % name)

    _rc, reach, modules, nfiles, dump = emu_reach("green")
    print("ELAB_STAGE dump=%s (post-elaboration, dead generate arms pruned)" % dump)
    if TOP not in modules:
        print("TRUNK_ELAB_FAIL: %s did not elaborate" % TOP, file=sys.stderr)
        return 1
    if PRODUCT_ROOT not in reach:
        print("TRUNK_UNREACHABLE %s root=%s  <-- the product decoder is DEAD"
              % (PRODUCT_ROOT, TOP), file=sys.stderr)
        return 1
    print("TRUNK_REACHABLE %s root=%s" % (PRODUCT_ROOT, TOP))

    absent = [m for m in REQUIRED if m not in reach]
    if absent:
        for m in absent:
            print("ELAB_MODULE_UNREACHABLE %s root=%s" % (m, TOP), file=sys.stderr)
        return 1
    for m in REQUIRED:
        print("ELAB_MODULE_REACHABLE %s root=%s" % (m, TOP))

    sp_original = STREAM_PATH.read_text()
    qip_original = qip_text
    proved = []
    try:
        head, body, tail = cut(sp_original, CORE_ANCHOR)

        STREAM_PATH.write_text(head + "/* CUT\n" + body + "\nCUT */" + tail)
        _rc, red, _m, _n, _d = emu_reach("red_cut")
        if PRODUCT_ROOT in red:
            print("TRUNK_ELAB_FAIL: %s still reachable from %s after cutting its only "
                  "instantiation - the trunk proof is not load-bearing"
                  % (PRODUCT_ROOT, TOP), file=sys.stderr)
            return 1
        proved.append("cut instantiation")
        print("OK trunk red-check A: %s unreachable from %s when its instantiation is cut"
              % (PRODUCT_ROOT, TOP))
        STREAM_PATH.write_text(sp_original)

        disabled = (head + "\tgenerate if (1'b0) begin : g_w_swap_o5_disabled_probe\n"
                    + body + "\n\tend endgenerate\n" + tail)
        STREAM_PATH.write_text(disabled)
        _rc, red, _m, _n, _d = emu_reach("red_gen0")
        gen_caught = PRODUCT_ROOT not in red
        STREAM_PATH.write_text(sp_original)
        if not gen_caught:
            print("TRUNK_ELAB_FAIL: %s still reachable from %s when its instantiation "
                  "is wrapped in a disabled if(0) generate - w-audit attack 1 defeats "
                  "this gate" % (PRODUCT_ROOT, TOP), file=sys.stderr)
            return 1
        proved.append("disabled generate")
        print("OK trunk red-check B: %s unreachable from %s when its instantiation "
              "is wrapped in a disabled if(0) generate" % (PRODUCT_ROOT, TOP))

        FILES_QIP.write_text("\n".join(
            ln for ln in qip_original.splitlines() if DPB_FILE not in ln) + "\n")
        _rc, red, _m, _n, _d = emu_reach("red_qip")
        qip_caught = not any(m in red for m in
                             ("h264_dpb_one_ref", "h264_inter_mc_part", "h264_inter_mc_16x16"))
        FILES_QIP.write_text(qip_original)
        if not qip_caught:
            print("TRUNK_ELAB_FAIL: MC modules still reachable after removing %s "
                  "from files.qip - the gate is not reading the Quartus file list"
                  % DPB_FILE, file=sys.stderr)
            return 1
        proved.append("files.qip removal")
        print("OK trunk red-check C: MC modules unreachable from %s when %s is "
              "dropped from files.qip" % (TOP, DPB_FILE))

        # w-audit attack 2 is a false *negative* against the regex checker: an
        # escaped instance name is a legal, genuinely instantiated cell, but the
        # regex reads it as absent. A parser must still see it.
        escaped = sp_original.replace(") product_decode_core (",
                                      ") \\product_decode_core  (")
        if escaped == sp_original:
            print("TRUNK_ELAB_FAIL: escaped-identifier mutation anchor not found",
                  file=sys.stderr)
            return 1
        STREAM_PATH.write_text(escaped)
        _rc, esc, _m, _n, _d = emu_reach("mut_escaped")
        STREAM_PATH.write_text(sp_original)
        if PRODUCT_ROOT not in esc or any(m not in esc for m in REQUIRED):
            print("TRUNK_ELAB_FAIL: escaped instance name (\\product_decode_core ) made "
                  "the trunk look dead - false negative, w-audit attack 2 defeats this "
                  "gate", file=sys.stderr)
            return 1
        proved.append("escaped identifier (no false negative)")
        print("OK trunk mutation-check D: escaped instance name still resolves; "
              "%s and %d/%d MC modules remain reachable from %s"
              % (PRODUCT_ROOT, len(REQUIRED), len(REQUIRED), TOP))
    finally:
        STREAM_PATH.write_text(sp_original)
        FILES_QIP.write_text(qip_original)

    _rc, reach, _m, nfiles, _d = emu_reach("green")
    if PRODUCT_ROOT not in reach or any(m not in reach for m in REQUIRED):
        print("TRUNK_ELAB_FAIL: sources did not restore cleanly", file=sys.stderr)
        return 1

    print("OK %s trunk: reachable from %s in the elaborated Quartus design; %d/%d "
          "required MC modules end-to-end; quartus_files=%d red_proofs=%d (%s)"
          % (PRODUCT_ROOT, TOP, len(REQUIRED), len(REQUIRED), nfiles, len(proved),
             ", ".join(proved)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
