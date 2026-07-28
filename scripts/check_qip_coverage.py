#!/usr/bin/env python3
"""Cross-check tracked RTL against the Quartus file list (files.qip).

Parent ruling (revised reachability standard, item 3): "Cross-check files.qip.
Not in the Quartus file list = not in the design, whatever the graph says."

A module can pass every source-level reachability check and still be absent from
the bitstream because its file was never handed to Quartus. This gate closes
that hole. It is a *file-list* oracle only: it proves a file is compiled, not
that the module inside it is instantiated. Pair it with both reachability
directions (subtree and trunk) and with `make post-fit-hierarchy`.

Exit codes:
  0  all tracked product RTL is in files.qip (and every --require is present)
  1  at least one product RTL file is tracked but not compiled
  2  refusal: Scope: 0 (empty file list or no tracked RTL) -- cannot claim a PASS
 77  skip (files.qip absent)
"""

import argparse
import os
import re
import subprocess
import sys

QIP = "fpga/Plex_MiSTer/files.qip"
RTL_GLOB = "fpga/Plex_MiSTer/rtl/*.sv"

# Files that are legitimately absent from the Quartus file list. Each entry
# must carry a reason; an unexplained exclusion is how a real defect hides.
ALLOWED_ABSENT = {
    "h264_decode_skeleton.sv": "retired lineage (architectural ruling); not a product module",
    "cos.sv": "unused helper, never instantiated by the product",
}


def qip_basenames(path):
    names = set()
    pat = re.compile(
        r"set_global_assignment\s+-name\s+(?:SYSTEMVERILOG|VERILOG|VHDL)_FILE\s+(\S+)",
        re.I,
    )
    with open(path, errors="ignore") as fh:
        for line in fh:
            m = pat.search(line)
            if m:
                names.add(os.path.basename(m.group(1).strip('"')))
    return names


def tracked_rtl():
    out = subprocess.run(
        ["git", "ls-files", RTL_GLOB], capture_output=True, text=True
    ).stdout.split()
    return [os.path.basename(p) for p in out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--require",
        action="append",
        default=[],
        metavar="MODULE",
        help="assert this module's source file is in files.qip (repeatable)",
    )
    args = ap.parse_args()

    if not os.path.exists(QIP):
        print(f"Scope: 0 -- {QIP} not found")
        print("SKIP: no Quartus file list to cross-check")
        return 77

    qip = qip_basenames(QIP)
    tracked = tracked_rtl()

    print(f"Scope: {len(qip)} files in {QIP}; {len(tracked)} .sv tracked under rtl/")
    if not qip or not tracked:
        print("REFUSED: Scope: 0 on one side -- a PASS cannot be claimed")
        return 2

    # Testbenches are never compiled into the product bitstream.
    product = [t for t in tracked if not t.startswith("tb_")]
    benches = len(tracked) - len(product)

    missing = sorted(t for t in product if t not in qip)
    unexplained = [t for t in missing if t not in ALLOWED_ABSENT]

    print(f"product RTL: {len(product)}  (testbenches excluded: {benches})")
    print(f"tracked but NOT compiled: {len(missing)} / {len(product)}")
    for t in missing:
        why = ALLOWED_ABSENT.get(t)
        tag = "ALLOWED_ABSENT" if why else "NOT_COMPILED"
        print(f"  {tag} {t}" + (f"  -- {why}" if why else ""))

    rc = 0
    for mod in args.require:
        fname = mod if mod.endswith(".sv") else mod + ".sv"
        if fname in qip:
            print(f"REQUIRED_FILE_COMPILED {fname}")
        else:
            in_git = "tracked-in-git" if fname in tracked else "not-tracked"
            print(f"REQUIRED_FILE_NOT_COMPILED {fname} ({in_git}) -- not in {QIP}")
            rc = 1

    if unexplained:
        print(
            f"QIP_COVERAGE_FAIL unexplained_absent={len(unexplained)} "
            f"({', '.join(unexplained)})"
        )
        rc = 1
    elif rc == 0:
        print(f"QIP_COVERAGE_OK product={len(product)} compiled={len(product) - len(missing)}")

    return rc


if __name__ == "__main__":
    sys.exit(main())
