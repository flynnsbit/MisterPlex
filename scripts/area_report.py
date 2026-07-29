#!/usr/bin/env python3
"""Per-module area report from a Quartus Analysis & Synthesis (map) report.

Area is the binding constraint on the DE10-Nano and a full fit costs ~11
minutes of the exclusive slot, so workers need to answer "did my module get
smaller?" without consuming that slot.  quartus_map alone gives per-entity
ALUT/register/DSP/memory estimates and needs no fitter and no timing.

Usage:
    scripts/area_report.py MAP_RPT [--baseline FILE] [--top N] [--json OUT]
    scripts/area_report.py MAP_RPT --save-baseline FILE

Exit codes: 0 report produced (and, with --baseline, no module regressed)
            1 a module grew past its baseline, or a device limit is exceeded
            2 the report could not be parsed
"""

import argparse
import json
import os
import sys

# 5CSEBA6U23I7, the DE10-Nano part.
DEVICE = "5CSEBA6U23I7"
ALM_BUDGET = 41910
DSP_BUDGET = 112
MEM_BUDGET = 5662720
# Quartus A&S reports combinational ALUTs; the fitter packs them into ALMs.
# Measured on the 2026-07-28 baseline fit: 165,671 ALUTs -> 104,023 ALMs.
ALUT_TO_ALM = 104023.0 / 165671.0


def parse(path):
    lines = open(path, errors="ignore").read().split("\n")
    try:
        i = next(k for k, l in enumerate(lines)
                 if l.startswith("; Compilation Hierarchy Node"))
    except StopIteration:
        return None, None
    cuts = [p for p, c in enumerate(lines[i - 1]) if c == "+"]

    def cols(line):
        return [line[cuts[j] + 1:cuts[j + 1]] for j in range(len(cuts) - 1)]

    hdr = [c.strip() for c in cols(lines[i])]
    idx = {name: hdr.index(name) for name in hdr}
    rows = []
    for line in lines[i + 2:]:
        if line.startswith("+"):
            break
        if not line.startswith(";"):
            continue
        c = cols(line)
        raw = c[0].rstrip()
        name = raw.strip().strip("|").split("|")[0].strip()
        if not name:
            continue

        def num(key):
            if key not in idx:
                return 0
            tok = c[idx[key]].strip().replace(",", "").split()
            try:
                return int(tok[0])
            except (ValueError, IndexError):
                return 0

        rows.append({
            "name": name,
            "depth": (len(raw) - len(raw.lstrip())) // 3,
            "alut": num("Combinational ALUTs"),
            "reg": num("Dedicated Logic Registers"),
            "dsp": num("DSP Blocks"),
            "mem": num("Block Memory Bits"),
        })
    return rows, hdr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("map_rpt")
    ap.add_argument("--baseline")
    ap.add_argument("--save-baseline")
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--json")
    ap.add_argument("--tolerance", type=float, default=0.02,
                    help="fractional growth allowed before a module FAILs")
    args = ap.parse_args()

    if not os.path.exists(args.map_rpt):
        print(f"AREA_PARSE_FAIL missing {args.map_rpt}")
        return 2
    rows, _ = parse(args.map_rpt)
    if not rows:
        print(f"AREA_PARSE_FAIL no entity table in {args.map_rpt}")
        return 2

    top = rows[0]
    alm_est = top["alut"] * ALUT_TO_ALM
    print(f"AREA device={DEVICE} source={os.path.basename(args.map_rpt)} "
          f"stage=map/A&S (no fit, no timing)")
    print(f"  top={top['name']} ALUTs={top['alut']:,} "
          f"est_ALMs={alm_est:,.0f}/{ALM_BUDGET:,} ({100*alm_est/ALM_BUDGET:.0f}%)  "
          f"DSP={top['dsp']}/{DSP_BUDGET} ({100*top['dsp']/DSP_BUDGET:.0f}%)  "
          f"MEM={top['mem']:,}/{MEM_BUDGET:,} ({100*top['mem']/MEM_BUDGET:.0f}%)")

    over = []
    if alm_est > ALM_BUDGET:
        over.append(f"ALM est {alm_est:,.0f} > {ALM_BUDGET:,}")
    if top["dsp"] > DSP_BUDGET:
        over.append(f"DSP {top['dsp']} > {DSP_BUDGET}")
    if top["mem"] > MEM_BUDGET:
        over.append(f"MEM {top['mem']:,} > {MEM_BUDGET:,}")

    print(f"\n  {'ALUTs':>9} {'DSP':>5} {'regs':>8}  module")
    for r in sorted(rows[1:], key=lambda x: -x["alut"])[:args.top]:
        print(f"  {r['alut']:9,} {r['dsp']:5d} {r['reg']:8,}  {r['name'][:64]}")

    current = {r["name"]: {"alut": r["alut"], "dsp": r["dsp"]} for r in rows}
    if args.save_baseline:
        with open(args.save_baseline, "w") as fh:
            json.dump({"device": DEVICE, "map_rpt": args.map_rpt,
                       "modules": current}, fh, indent=1, sort_keys=True)
        print(f"\nBASELINE_SAVED {args.save_baseline} modules={len(current)}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"device": DEVICE, "modules": current}, fh, indent=1,
                      sort_keys=True)

    regressed = []
    if args.baseline:
        base = json.load(open(args.baseline))["modules"]
        print(f"\n  vs baseline {os.path.basename(args.baseline)}:")
        deltas = []
        for name, cur in current.items():
            b = base.get(name)
            if not b:
                continue
            da, dd = cur["alut"] - b["alut"], cur["dsp"] - b["dsp"]
            if da or dd:
                deltas.append((da, dd, name, b["alut"]))
            if b["alut"] > 0 and da > b["alut"] * args.tolerance:
                regressed.append((name, b["alut"], cur["alut"]))
            elif b["alut"] == 0 and da > 0:
                regressed.append((name, 0, cur["alut"]))
        for da, dd, name, was in sorted(deltas)[:args.top]:
            sign = "+" if da > 0 else ""
            print(f"  {sign}{da:>9,} ALUT {'+' if dd>0 else ''}{dd:>4} DSP  "
                  f"{name[:52]} (was {was:,})")
        gone = sorted(set(base) - set(current))
        if gone:
            print(f"  REMOVED from hierarchy: {', '.join(g[:40] for g in gone[:8])}"
                  + (" ..." if len(gone) > 8 else ""))

    if regressed:
        for name, was, now in regressed[:10]:
            print(f"AREA_REGRESSION {name} {was:,} -> {now:,} ALUTs")
    if over:
        print("AREA_OVER_BUDGET " + "; ".join(over))
    if regressed or over:
        print("AREA_FAIL")
        return 1
    print("AREA_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
