#!/usr/bin/env python3
"""Product-reachability evidence for a required set of RTL modules.

Why this exists
---------------
`scripts/check_rtl_module_instantiations.py --root h264_decode_core` answers
"is this module inside the h264_decode_core source subtree?".  w-audit proved
that question can be answered **green while the core itself is not connected to
`emu` at all** (`--root emu --require h264_decode_core` -> rc=1,
`parents=<none>`).  A subtree proof without a trunk proof is vacuous.

w-audit also measured three source-level blind spots in that checker:

  * an instantiation inside a disabled ``if (0)`` generate reads as reachable,
  * a legal escaped instance name (``\\name ``) reads as unreachable,
  * an RTL file tracked in git but **absent from files.qip** reads as reachable
    even though Quartus never compiles it.

So this helper does three things the single invocation cannot:

  1. runs the subtree check,
  2. runs the **trunk** check (`emu` -> the product root module), and
  3. cross-checks that every file defining a required module is listed in
     `files.qip` -- not in the Quartus file list means not in the design,
     whatever the instantiation graph says.

It then prints one explicit verdict line.  It never upgrades a core-subtree
result into a product claim, and it hard-fails when the repository contradicts
itself: if `stream_path.sv` textually instantiates the product root but `emu`
cannot reach it, that is broken wiring, not a pending integration.

Source-level graphs remain a cheap pre-filter.  `make post-fit-hierarchy` is
the only real oracle.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL_DIR = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
QIP = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
CHECKER = ROOT / "scripts" / "check_rtl_module_instantiations.py"
QIP_COVERAGE = ROOT / "scripts" / "check_qip_coverage.py"
PREFIT_HIER = ROOT / "scripts" / "check_prefit_hierarchy.py"

MODULE_DECL = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)", re.MULTILINE)


def run_checker(root: str, requires: list[str]) -> tuple[int, str]:
    cmd = [sys.executable, str(CHECKER), "--root", root]
    for name in requires:
        cmd += ["--require", name]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def module_files() -> dict[str, Path]:
    found: dict[str, Path] = {}
    for path in sorted(RTL_DIR.rglob("*.sv")) + sorted(RTL_DIR.rglob("*.v")):
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for name in MODULE_DECL.findall(text):
            found.setdefault(name, path)
    return found


def qip_files() -> set[str]:
    if not QIP.is_file():
        return set()
    listed: set[str] = set()
    for line in QIP.read_text(errors="replace").splitlines():
        m = re.search(r"(?:SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE)\s+(\S+)", line)
        if m:
            listed.add(m.group(1).strip().strip('"'))
    return listed


def stream_path_instantiates(product_root: str) -> bool:
    sp = RTL_DIR / "stream_path.sv"
    if not sp.is_file():
        return False
    text = sp.read_text(errors="replace")
    # strip line comments so a commented-out instance does not count
    text = re.sub(r"//[^\n]*", "", text)
    return re.search(rf"^\s*{re.escape(product_root)}\s*(?:#\s*\(|[A-Za-z_\\])", text,
                     re.MULTILINE) is not None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--product-root", default="h264_decode_core",
                    help="module that must be reachable from the synthesis root")
    ap.add_argument("--synthesis-root", default="emu")
    ap.add_argument("--require", action="append", default=[],
                    help="module that must be inside the product root subtree")
    ap.add_argument("--label", default="product")
    ap.add_argument("--prefit", action="store_true",
                    help="Also run the pre-fit elaboration oracle "
                         "(slower; elaborates the whole product top).")
    args = ap.parse_args()

    if not args.require:
        print("PRODUCT_REACH_ERROR: no --require modules given", file=sys.stderr)
        return 2

    failures: list[str] = []

    # ── 1. subtree ────────────────────────────────────────────────────────
    sub_rc, sub_out = run_checker(args.product_root, args.require)
    print(sub_out)
    print(f"PRODUCT_REACH subtree root={args.product_root} rc={sub_rc}")
    if sub_rc != 0:
        failures.append(f"subtree {args.product_root} rc={sub_rc}")

    # ── 2. trunk ──────────────────────────────────────────────────────────
    trunk_rc, trunk_out = run_checker(args.synthesis_root, [args.product_root])
    print(trunk_out)
    print(f"PRODUCT_REACH trunk root={args.synthesis_root} "
          f"require={args.product_root} rc={trunk_rc}")

    wired = stream_path_instantiates(args.product_root)
    print(f"PRODUCT_REACH stream_path_instantiates_{args.product_root}={int(wired)}")
    if wired and trunk_rc != 0:
        failures.append(
            f"stream_path.sv instantiates {args.product_root} but {args.synthesis_root} "
            f"cannot reach it: the product trunk is broken, not pending")

    # ── 3. files.qip cross-check ──────────────────────────────────────────
    # Tracked in git is not enough.  Absent from the Quartus file list means the
    # module is not in the bitstream, whatever the graph says.
    defined = module_files()
    listed = qip_files()
    for name in list(args.require) + [args.product_root]:
        path = defined.get(name)
        if path is None:
            failures.append(f"no RTL file defines module {name}")
            continue
        rel = path.relative_to(RTL_DIR.parent).as_posix()
        in_qip = rel in listed
        print(f"PRODUCT_REACH qip module={name} file={rel} in_files_qip={int(in_qip)}")
        if not in_qip:
            failures.append(f"{rel} defines {name} but is not listed in files.qip")

    # ── verdict ───────────────────────────────────────────────────────────
    # w-fit-o5 measured two tracked RTL files that Quartus was never given, on
    # the branch the deployed RBF came from.  Their whole-tree gate is strictly
    # stronger than the per-module check above, so delegate to it rather than
    # duplicating it -- but only let it decide the *product* verdict, exactly as
    # the trunk result does.  A skip is not a pass: rc=77 is treated as unproven.
    cov_rc = None
    if QIP_COVERAGE.is_file():
        cov = subprocess.run([sys.executable, str(QIP_COVERAGE)],
                             capture_output=True, text=True)
        cov_rc = cov.returncode
        print(f"PRODUCT_REACH qip_coverage rc={cov_rc}"
              f"{' (77 = skip, not a pass)' if cov_rc == 77 else ''}")
        if cov_rc != 0:
            for line in (cov.stdout + cov.stderr).strip().splitlines():
                print(f"PRODUCT_REACH qip_coverage| {line}")
        if trunk_rc == 0 and cov_rc != 0:
            failures.append(
                f"{args.synthesis_root} reaches {args.product_root}, so this branch "
                f"claims to be integrated, but check_qip_coverage.py returned "
                f"rc={cov_rc}: product RTL is tracked in git and never compiled")
    else:
        print("PRODUCT_REACH qip_coverage rc=absent "
              "(scripts/check_qip_coverage.py not on this branch)")

    # Fourth oracle, opt-in because it elaborates the entire product top.
    # Source graphs and file lists are both blind to a module that elaborates
    # away; this one is not.  RULING 3 condition 4 asks for exactly this before
    # any further fit is authorised.
    prefit_rc = None
    if args.prefit:
        if not PREFIT_HIER.is_file():
            print("PRODUCT_REACH prefit_hierarchy rc=absent "
                  "(scripts/check_prefit_hierarchy.py not on this branch)")
        else:
            pf_cmd = [sys.executable, str(PREFIT_HIER),
                      "--label", f"{args.label}-prefit",
                      "--top", args.synthesis_root,
                      "--require", args.product_root]
            for m in args.require:
                pf_cmd += ["--require", m]
            pf = subprocess.run(pf_cmd, capture_output=True, text=True)
            prefit_rc = pf.returncode
            print(f"PRODUCT_REACH prefit_hierarchy rc={prefit_rc}"
                  f"{' (77 = skip, not a pass)' if prefit_rc == 77 else ''}")
            for line in (pf.stdout + pf.stderr).strip().splitlines():
                print(f"PRODUCT_REACH prefit| {line}")
            if prefit_rc != 0:
                failures.append(
                    f"pre-fit elaboration of {args.synthesis_root} returned "
                    f"rc={prefit_rc}: at least one required module is not in the "
                    f"elaborated design. Source-level reachability can be green "
                    f"while this is red -- believe this one")

    if failures:
        for f in failures:
            print(f"PRODUCT_REACH_FAIL: {f}", file=sys.stderr)
        return 1

    if trunk_rc == 0:
        print(f"PRODUCT_REACH_OK label={args.label} scope=PRODUCT_REACHABLE "
              f"trunk={args.synthesis_root}->{args.product_root} "
              f"subtree={args.product_root}->{','.join(args.require)} "
              f"files_qip=checked qip_coverage_rc={cov_rc} "
              f"prefit_hierarchy_rc={prefit_rc} "
              f"(make post-fit-hierarchy is still the only oracle for the bitstream)")
    else:
        print(f"PRODUCT_REACH_OK label={args.label} scope=CORE_SUBTREE_ONLY "
              f"NOT_PRODUCT_REACHABLE trunk={args.synthesis_root}->{args.product_root} "
              f"rc={trunk_rc} "
              f"subtree={args.product_root}->{','.join(args.require)} "
              f"files_qip=checked -- this is NOT a product claim: "
              f"{args.product_root} is not connected to {args.synthesis_root} on this "
              f"branch, so nothing below may be cited as shipping behaviour")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
