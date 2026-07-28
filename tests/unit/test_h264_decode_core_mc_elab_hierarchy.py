#!/usr/bin/env python3
"""Elaboration-aware reachability gate for motion compensation inside h264_decode_core.

The registered instrument scripts/check_rtl_module_instantiations.py is source/regex
level: an adversarial audit found it has both false-reachable and false-unreachable
blind spots. This gate is a second, independent oracle that is *elaboration* aware.

It asks Verilator to elaborate the product decode core (rooted at the decode-core
testbench top, whose only DUT instance is h264_decode_core), dumps the post-parameter
AST, and reconstructs the real module instance graph from CELL -> MODULE links. A
module can only appear here if the elaborator actually built it.

Two properties are checked:

  1. every required MC/DPB/reference module is in the elaborated subtree of
     h264_decode_core;
  2. decode_stub is not elaborated at all under this root, so the retired diagnostic
     painter cannot be manufacturing a false green (the masking effect that made plain
     emu-rooted reachability worthless).

Every green ships with its red: each required module's product instantiation is cut
out of the source, the design is re-elaborated, and the module must disappear from the
elaborated subtree. Sources are restored in a finally block.
"""

import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
BUILD = ROOT / "build" / "verilator" / "h264_decode_core_elab_hierarchy"

TB_TOP = ROOT / "tests" / "rtl" / "h264_decode_core_p16z_tb.sv"
TOP_MODULE = "h264_decode_core_p16z_tb"
PRODUCT_ROOT = "h264_decode_core"
BANNED_UNDER_ROOT = "decode_stub"

RTL_FILES = [
    RTL / "h264_cavlc_residual.sv",
    RTL / "h264_iq_idct_4x4.sv",
    RTL / "h264_intra_pred.sv",
    RTL / "h264_intra_nb_ctx.sv",
    RTL / "h264_decode_top.sv",
    RTL / "h264_inter_pred.sv",
    RTL / "h264_deblock.sv",
    RTL / "h264_decode_core.sv",
    RTL / "h264_dpb.sv",
]

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

# module -> (source file, instantiation anchor). Cutting the anchor's instantiation
# must remove the module from the elaborated subtree.
CUT_SITES = {
    "h264_inter_mc_part": (RTL / "h264_decode_core.sv", "h264_inter_mc_part u_product_p16_mc"),
    "h264_inter_mc_16x16": (RTL / "h264_dpb.sv", "h264_inter_mc_16x16 u_full"),
    "h264_luma_qpel_block_16x16": (RTL / "h264_dpb.sv", "h264_luma_qpel_block_16x16 u_luma"),
    "h264_chroma_epel_block_8x8": (RTL / "h264_dpb.sv", "h264_chroma_epel_block_8x8 u_chroma_u"),
    "h264_dpb_one_ref": (RTL / "h264_decode_core.sv", "h264_dpb_one_ref #("),
    "h264_luma_ref_tap_addr": (RTL / "h264_dpb.sv", "h264_luma_ref_tap_addr #(.TAP_COLS(21)"),
    "h264_ref_clamp": (RTL / "h264_inter_pred.sv", "h264_ref_clamp u_clamp"),
    "h264_deblock_writeback_ctrl": (RTL / "h264_decode_core.sv", "h264_deblock_writeback_ctrl #("),
}

# h264_chroma_epel_block_8x8 and h264_luma_ref_tap_addr each have a second product
# instantiation that must be cut at the same time for the module to disappear.
EXTRA_CUT_SITES = {
    "h264_chroma_epel_block_8x8": [(RTL / "h264_dpb.sv", "h264_chroma_epel_block_8x8 u_chroma_v")],
    "h264_luma_ref_tap_addr": [(RTL / "h264_dpb.sv", "h264_luma_ref_tap_addr #(.TAP_COLS(9)")],
}


def elaborate(tag):
    """Run Verilator lint-only with an AST dump; return (rc, dump_dir)."""
    mdir = BUILD / tag
    mdir.mkdir(parents=True, exist_ok=True)
    for stale in mdir.glob("*.tree.json"):
        stale.rename(mdir / (stale.name + ".prev"))
    cmd = [
        str(ROOT / "scripts" / "run_verilator.sh"),
        "--lint-only",
        "--dump-tree-json",
        "--Mdir", str(mdir),
        "--top-module", TOP_MODULE,
        "-Wno-fatal",
        "-GFRAME_W=624",
        "-GFRAME_H=480",
        str(TB_TOP),
    ] + [str(f) for f in RTL_FILES]
    log = mdir / "lint.log"
    with open(log, "w") as fh:
        rc = subprocess.call(cmd, cwd=str(ROOT), stdout=fh, stderr=subprocess.STDOUT)
    return rc, mdir


def instance_graph(mdir):
    """Reconstruct module -> [(instance, module)] from the richest AST dump."""
    best = None
    for dump in sorted(mdir.glob("*.tree.json")):
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
                cells.append((owner, node.get("name"), node.get("modp")))
            for value in node.values():
                if isinstance(value, list):
                    for child in value:
                        if isinstance(child, dict):
                            walk(child, owner)
                elif isinstance(value, dict):
                    walk(value, owner)

        walk(tree, None)
        resolved = [
            (modules.get(p), n, modules.get(m))
            for p, n, m in cells
            if modules.get(p) and modules.get(m)
        ]
        if best is None or len(resolved) > len(best[1]):
            best = (dump.name, resolved, set(modules.values()))
    if best is None:
        return None, [], set()
    return best[0], best[1], best[2]


def subtree(edges, root):
    graph = {}
    for parent, inst, child in edges:
        graph.setdefault(parent, set()).add(child)
    seen = set()
    stack = [root]
    while stack:
        node = stack.pop()
        for child in graph.get(node, ()):
            if child not in seen:
                seen.add(child)
                stack.append(child)
    return seen


def measure(tag):
    rc, mdir = elaborate(tag)
    dump, edges, modules = instance_graph(mdir)
    reach = subtree(edges, PRODUCT_ROOT) if edges else set()
    return rc, dump, reach, modules


def cut_instantiation(text, anchor):
    """Comment out the instantiation statement that begins at anchor."""
    start = text.index(anchor)
    line_start = text.rfind("\n", 0, start) + 1
    depth = 0
    idx = start
    opened = False
    while idx < len(text):
        ch = text[idx]
        if ch == "(":
            depth += 1
            opened = True
        elif ch == ")":
            depth -= 1
            if opened and depth == 0:
                semi = text.index(";", idx)
                end = semi + 1
                break
        idx += 1
    else:
        raise RuntimeError("could not find end of instantiation for " + anchor)
    return text[:line_start] + "/* CUT\n" + text[line_start:end] + "\nCUT */" + text[end:]


def main():
    if not TB_TOP.exists():
        print("ELAB HIERARCHY ERROR: missing %s" % TB_TOP, file=sys.stderr)
        return 2

    probe = subprocess.run(
        [str(ROOT / "scripts" / "run_verilator.sh"), "--version"],
        cwd=str(ROOT), capture_output=True, text=True)
    if probe.returncode == 127:
        print("ELAB HIERARCHY ERROR: Verilator not found; refusing to report PASS "
              "without elaborating the design.", file=sys.stderr)
        return 3
    if probe.returncode != 0:
        print("ELAB HIERARCHY ERROR: Verilator probe failed rc=%d: %s"
              % (probe.returncode, probe.stdout + probe.stderr), file=sys.stderr)
        return probe.returncode

    print("Scope: elaboration-aware (Verilator AST) reachability for %d required MC/DPB/"
          "reference modules under %s, with a cut-instantiation red proof for each"
          % (len(REQUIRED), PRODUCT_ROOT))

    rc, dump, reach, modules = measure("green")
    if rc != 0:
        print("ELAB HIERARCHY FAIL: baseline elaboration failed rc=%d (see %s)"
              % (rc, BUILD / "green" / "lint.log"), file=sys.stderr)
        return 1
    if PRODUCT_ROOT not in modules:
        print("ELAB HIERARCHY FAIL: %s was not elaborated at all" % PRODUCT_ROOT,
              file=sys.stderr)
        return 1

    missing = [m for m in REQUIRED if m not in reach]
    if missing:
        for m in missing:
            print("ELAB_MODULE_UNREACHABLE %s root=%s" % (m, PRODUCT_ROOT), file=sys.stderr)
        print("ELAB HIERARCHY FAIL: %d required module(s) absent from the elaborated "
              "subtree of %s" % (len(missing), PRODUCT_ROOT), file=sys.stderr)
        return 1

    if BANNED_UNDER_ROOT in modules:
        print("ELAB HIERARCHY FAIL: %s was elaborated under this root; a green here "
              "could be masked by the retired diagnostic painter"
              % BANNED_UNDER_ROOT, file=sys.stderr)
        return 1

    for m in REQUIRED:
        print("ELAB_MODULE_REACHABLE %s root=%s" % (m, PRODUCT_ROOT))

    originals = {}
    proved = 0
    try:
        for module in REQUIRED:
            sites = [CUT_SITES[module]] + EXTRA_CUT_SITES.get(module, [])
            for path, anchor in sites:
                if path not in originals:
                    originals[path] = path.read_text()
                text = path.read_text()
                if anchor not in text:
                    print("ELAB HIERARCHY FAIL: cut anchor not found for %s: %r"
                          % (module, anchor), file=sys.stderr)
                    return 1
                path.write_text(cut_instantiation(text, anchor))
            red_rc, _, red_reach, _ = measure("red")
            for path, text in originals.items():
                path.write_text(text)
            if module in red_reach:
                print("ELAB HIERARCHY FAIL: %s still elaborated under %s after cutting "
                      "its %d product instantiation site(s) (elaboration rc=%d) - the "
                      "green is not load-bearing"
                      % (module, PRODUCT_ROOT, len(sites), red_rc), file=sys.stderr)
                return 1
            proved += 1
            print("OK %s elab red-check: %s absent from the elaborated subtree when its "
                  "%d product instantiation site(s) are cut" % (PRODUCT_ROOT, module, len(sites)))
    finally:
        for path, text in originals.items():
            path.write_text(text)

    rc, dump, reach, modules = measure("green")
    if rc != 0 or any(m not in reach for m in REQUIRED):
        print("ELAB HIERARCHY FAIL: sources did not restore cleanly (rc=%d)" % rc,
              file=sys.stderr)
        return 1

    print("OK %s MC elaboration hierarchy: %d/%d required modules present in the "
          "elaborated subtree; %s not elaborated under this root; elaborated_modules=%d "
          "subtree_modules=%d dump=%s"
          % (PRODUCT_ROOT, proved, len(REQUIRED), BANNED_UNDER_ROOT,
             len(modules), len(reach), dump))
    return 0


if __name__ == "__main__":
    sys.exit(main())
