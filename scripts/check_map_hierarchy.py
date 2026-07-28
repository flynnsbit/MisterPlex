#!/usr/bin/env python3
"""Assert modules are present in a Quartus entity-hierarchy report.

Works on both:
  * `output_files/Plex.map.rpt` -- Analysis & Synthesis, available PRE-FIT (minutes)
  * `output_files/Plex.fit.rpt` -- Fitter, available only after a full fit (hours)

Why this exists (parent ruling 3, condition 4): source-level reachability is
regex-based and has been shown to be wrong in both directions -- it passes an
instantiation inside a disabled `if (0)` generate, fails on escaped identifiers
(`\\name `), and cannot see that a file is missing from files.qip. Quartus itself
is elaboration-aware, so an entity report settles all of those at once. The map
report gives that answer WITHOUT paying for place-and-route.

This reports the module's parent chain, so a module reachable only through
`decode_stub` is not silently counted as product-reachable.

Exit codes:
  0  every --require module is present (and, with --under, under that parent)
  1  at least one required module is absent or misparented
  2  refusal: Scope: 0 -- no entity rows parsed, cannot claim a PASS
 77  skip: report file absent
"""

import argparse
import os
import re
import sys

# Inside the "Resource Utilization by Entity" table, rows look like:
#   ;    |alsa:alsa|                    ; 268.6 (268.6) ; ...
#   ;       |ddio_out_b2j:auto_generated| ; 0.0 (0.0)   ; ...
# Nesting is encoded by INDENT, not by a full path, so a stack keyed on the
# leading-space count is required to recover each node's parent chain.
SECTION_RE = re.compile(r"Resource Utilization by Entity", re.I)
NODE_RE = re.compile(r"^;(\s+)\|([A-Za-z_][\w$]*)(?::([^|]*))?\|?\s*$")
RULE_RE = re.compile(r"^\+[-+]+\+?\s*$")


def parse_entities(path):
    """Return a list of module chains (root..node) for every entity row.

    The table is BOUNDED: parsing starts at the section header and stops at the
    table's closing rule. An unbounded scan can absorb rows from a later,
    unrelated table and false-green a presence check, so the end delimiter is
    treated as significant rather than skipped.
    """
    rows = []
    stack = {}
    in_section = False
    seen_node = False
    with open(path, errors="ignore") as fh:
        for line in fh:
            if SECTION_RE.search(line):
                stack = {}
                in_section = True
                seen_node = False
                continue
            if not in_section:
                continue
            if RULE_RE.match(line):
                # Quartus brackets the table with +---+ rules: one before the
                # header, one after it, and one closing the body. Only the rule
                # that follows at least one node row terminates the table.
                if seen_node:
                    in_section = False
                    seen_node = False
                continue
            if not line.startswith(";"):
                continue
            parts = line.split(";")
            if len(parts) < 2:
                continue
            m = NODE_RE.match(";" + parts[1].rstrip())
            if not m:
                # Column headers, rules and prose rows are skipped, not treated
                # as end-of-table: the header row sits between the section title
                # and the first node and would otherwise truncate the scan.
                continue
            indent, module = len(m.group(1)), m.group(2)
            for k in [k for k in stack if k >= indent]:
                del stack[k]
            stack[indent] = module
            seen_node = True
            rows.append([stack[k] for k in sorted(stack)])
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report", help="Plex.map.rpt or Plex.fit.rpt")
    ap.add_argument("--require", action="append", default=[], metavar="MODULE")
    ap.add_argument(
        "--under",
        metavar="PARENT",
        help="additionally require each module to appear beneath PARENT",
    )
    ap.add_argument(
        "--forbid-only-under",
        metavar="PARENT",
        help="fail if a required module appears ONLY beneath PARENT "
        "(e.g. decode_stub masking)",
    )
    ap.add_argument(
        "--elab-log",
        metavar="LOG",
        help="synthesis log; lets an absent module be classified as "
        "ELABORATED_BUT_OPTIMIZED_AWAY rather than NEVER_ELABORATED",
    )
    args = ap.parse_args()

    # module -> set of elaborated hierarchy paths. The PATH matters: a module
    # elaborated only beneath decode_stub is not product-elaborated, and
    # reporting bare "elaborated" would reintroduce exactly the masking
    # confusion this gate exists to prevent.
    elaborated = {}
    if args.elab_log and os.path.exists(args.elab_log):
        elab_re = re.compile(
            r'Elaborating entity "([^"]+)"(?:\s+for hierarchy "([^"]*)")?'
        )
        with open(args.elab_log, errors="ignore") as fh:
            for line in fh:
                m = elab_re.search(line)
                if m:
                    elaborated.setdefault(m.group(1), set()).add(m.group(2) or "?")

    if not os.path.exists(args.report):
        print(f"Scope: 0 -- report not found: {args.report}")
        print("SKIP: no Quartus entity report to inspect")
        return 77

    rows = parse_entities(args.report)
    kind = "map/A&S (pre-fit)" if args.report.endswith(".map.rpt") else "fit (post-fit)"
    print(f"Scope: {len(rows)} entity rows parsed from {args.report} [{kind}]")
    print(f"required modules: {len(args.require)}")
    if not rows:
        print("REFUSED: Scope: 0 entity rows -- a PASS cannot be claimed")
        return 2
    if not args.require:
        print("REFUSED: Scope: 0 required modules -- nothing asserted")
        return 2

    rc = 0
    for mod in args.require:
        hits = [c for c in rows if mod in c]
        if not hits:
            if mod in elaborated:
                paths = sorted(elaborated[mod])
                via = sorted({
                    p.split("|")[-2].split(":")[0] for p in paths
                    if "|" in p and len(p.split("|")) >= 2
                })
                # Instantiated and elaborated, but contributed no resources, so
                # synthesis collapsed it. Source-level reachability CANNOT see
                # this: the instantiation is real. The usual cause is that the
                # module's outputs are unconsumed, which makes the whole
                # instance dead logic. The remedy is to consume the outputs,
                # NOT to "wire up the instantiation" -- it is already wired.
                print(
                    f"ABSENT {mod} -- ELABORATED_BUT_OPTIMIZED_AWAY "
                    f"parents={','.join(via) or '<top>'} "
                    "(instantiated, then removed as dead logic; outputs unconsumed)"
                )
                for pth in paths[:3]:
                    print(f"    elaborated_as: {pth}")
            elif elaborated:
                print(f"ABSENT {mod} -- NEVER_ELABORATED (not compiled or not instantiated)")
            else:
                print(f"ABSENT {mod} -- not in the {kind} hierarchy")
            rc = 1
            continue

        # A row is emitted per hierarchy node, so "mod appears in the chain"
        # counts the node itself PLUS all of its descendants. Report both, and
        # never label the subtree total as an instance count.
        exact = [c for c in hits if c[-1] == mod]
        parents = set()
        for chain in exact or hits:
            i = chain.index(mod)
            parents.add(chain[i - 1] if i > 0 else "<top>")
        plist = ",".join(sorted(parents))
        print(
            f"PRESENT {mod} instances={len(exact)} subtree_rows={len(hits)} "
            f"parents={plist}"
        )

        if args.under and not any(args.under in c[: c.index(mod)] for c in hits):
            print(f"  MISPARENTED {mod} -- never appears beneath {args.under}")
            rc = 1
        if args.forbid_only_under:
            # W-AUDIT broke the previous form, which compared only the IMMEDIATE
            # parent: h264_dpb_i420_addr nested under h264_dpb_one_ref under
            # decode_stub false-greened because its parent was not the stub.
            # Masking is an ANCESTOR property, so scan the whole chain above the
            # module in every occurrence.
            def masked(chain):
                return args.forbid_only_under in chain[: chain.index(mod)]

            occurrences = exact or hits
            clean = [c for c in occurrences if not masked(c)]
            if not clean:
                print(
                    f"  MASKED {mod} -- every occurrence is beneath "
                    f"{args.forbid_only_under}; this is not product reachability"
                )
                # parents= alone can hide a stub ancestor, so cite full paths.
                for chain in occurrences[:3]:
                    print(f"    hierarchy_path: {'|'.join(chain)}")
                rc = 1

    print(
        "PREFIT_HIERARCHY_OK" if rc == 0 else "PREFIT_HIERARCHY_FAIL",
        f"required={len(args.require)} rows={len(rows)}",
    )
    return rc


if __name__ == "__main__":
    sys.exit(main())
