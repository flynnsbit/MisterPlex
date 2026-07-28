#!/usr/bin/env python3
"""May a fit be requested? Answer the ruling's four-step order mechanically.

The parent's revised order, cheapest first:

    1. check_qip_coverage.py                (seconds)  is it compiled?
    2. --root emu --require <module>        (seconds)  is it instantiated?
    3. check_prefit_elaboration.sh          (~4m23s)   does it SURVIVE SYNTHESIS?
    4. full fit                             (~6h)      parent authorization only

Steps 1 and 2 were both green on `w-decode-hour27` `2f165ed` while
`h264_decode_core` was absent from Analysis & Synthesis. They are necessary and
jointly insufficient, and the ruling is that nobody requests a fit until step 3
shows the module PRESENT.

This gate refuses to be the fifth way to get a confident green:

  * **No step-3 evidence is 77 UNSCORED, never 0.** A missing measurement is not
    a passing measurement. That is the whole lesson of the four product-absence
    incidents.
  * **Evidence is bound to the source it was measured on.** A&S evidence from
    commit X does not license a fit of commit Y. The binding is the git tree
    hash of `fpga/Plex_MiSTer`, so an unrelated commit elsewhere does not
    invalidate it and an RTL edit does. Uncommitted changes under that path
    also invalidate it -- the evidence cannot have seen them.
  * It runs steps 1-3 itself rather than trusting a report of them, and reads
    each exit code directly. Two workers on this project have misread an exit
    status through a pipe in one shift; this file never pipes one.

It deliberately does **not** run Quartus. W-FIT-O5 holds the sole Quartus slot
and the deploy token; this gate consumes the artefact that run produces.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RTL_SUBTREE = "fpga/Plex_MiSTer"

READY, NOT_READY, REFUSED, UNSCORED = 0, 1, 2, 77


def run_gate(argv: list[str]) -> tuple[int, str]:
    """Run a sibling gate and read its exit code directly -- never through a pipe."""
    proc = subprocess.run(
        [sys.executable, *argv], capture_output=True, text=True, cwd=ROOT
    )
    return proc.returncode, proc.stdout + proc.stderr


def git(*args: str) -> tuple[int, str]:
    proc = subprocess.run(["git", *args], capture_output=True, text=True, cwd=ROOT)
    return proc.returncode, proc.stdout.strip()


def rtl_tree_hash(commit: str) -> str | None:
    rc, out = git("rev-parse", f"{commit}:{RTL_SUBTREE}")
    return out if rc == 0 and out else None


def dirty_rtl() -> list[str]:
    rc, out = git("status", "--porcelain", "--", RTL_SUBTREE)
    if rc != 0:
        return []
    return [line for line in out.splitlines() if line.strip()]


def parse_elaboration_evidence(text: str, module: str) -> tuple[str, str]:
    """Classify one module in a check_map_hierarchy.py / A&S log."""
    if re.search(rf"^\s*REFUSED\b", text, re.M):
        return "REFUSED", "the evidence file itself records a refusal"
    present = re.search(rf"^\s*PRESENT\s+{re.escape(module)}\b(.*)$", text, re.M)
    if present:
        return "PRESENT", present.group(1).strip()
    absent = re.search(rf"^\s*ABSENT\s+{re.escape(module)}\b\s*(?:--)?\s*(.*)$", text, re.M)
    if absent:
        return "ABSENT", absent.group(1).strip() or "no reason recorded"
    return "NOT_MENTIONED", "the evidence does not mention this module at all"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--module", action="append", default=[], metavar="NAME",
                    help="module that must be in the design (default h264_decode_core)")
    ap.add_argument("--elaboration-evidence", default=None, metavar="PATH",
                    help="log from check_prefit_elaboration.sh / check_map_hierarchy.py")
    ap.add_argument("--evidence-commit", default=None, metavar="SHA",
                    help="the commit that A&S evidence was measured on")
    args = ap.parse_args(argv)

    modules = args.module or ["h264_decode_core"]
    print(f"Scope: fit_readiness_steps=3 modules={len(modules)} "
          f"evidence={'yes' if args.elaboration_evidence else 'none'}")

    # Operator input is validated before anything expensive runs, and before any
    # verdict is printed: a malformed request is not a finding about the tree.
    evidence_path = None
    text = ""
    if args.elaboration_evidence:
        evidence_path = Path(args.elaboration_evidence)
        if not evidence_path.is_absolute():
            evidence_path = ROOT / evidence_path
        if not evidence_path.is_file():
            print(f"EVIDENCE_UNUSABLE not_found {evidence_path}")
            print("FIT_READINESS_REFUSED: named evidence does not exist", file=sys.stderr)
            return REFUSED
        text = evidence_path.read_text(encoding="utf-8", errors="ignore")
        if not text.strip():
            print(f"EVIDENCE_UNUSABLE empty {evidence_path}")
            print("FIT_READINESS_REFUSED: empty evidence cannot support a claim",
                  file=sys.stderr)
            return REFUSED
        if not args.evidence_commit:
            print("EVIDENCE_UNUSABLE unbound no --evidence-commit")
            print(
                "FIT_READINESS_REFUSED: --elaboration-evidence without "
                "--evidence-commit. Unbound evidence is how a measurement of one "
                "tree comes to license a fit of another.",
                file=sys.stderr,
            )
            return REFUSED
        if rtl_tree_hash(args.evidence_commit) is None:
            print(f"EVIDENCE_UNUSABLE unresolvable {args.evidence_commit}")
            print(
                f"FIT_READINESS_REFUSED: cannot resolve "
                f"{args.evidence_commit}:{RTL_SUBTREE}",
                file=sys.stderr,
            )
            return REFUSED

    findings: list[str] = []

    rc1, out1 = run_gate([str(HERE / "check_qip_coverage.py")])
    print(f"STEP1_COMPILED rc={rc1}")
    if rc1 != 0:
        findings.append(f"step 1 (files.qip coverage) rc={rc1}")
        for line in out1.splitlines():
            if "NOT_COMPILED" in line or "FAIL" in line:
                print(f"  {line.strip()}")

    for module in modules:
        rc2, out2 = run_gate([
            str(HERE / "check_rtl_module_instantiations.py"),
            "--root", "emu", "--require", module,
        ])
        print(f"STEP2_INSTANTIATED {module} rc={rc2}")
        if rc2 != 0:
            findings.append(f"step 2 (emu -> {module}) rc={rc2}")
            for line in out2.splitlines():
                if "UNREACHABLE" in line or "TRUNK" in line:
                    print(f"  {line.strip()}")

        rc3, out3 = run_gate([
            str(HERE / "check_dead_logic_pruning.py"), "--require", module,
        ])
        print(f"STEP2B_CAN_INFLUENCE_DESIGN {module} rc={rc3}")
        if rc3 == REFUSED:
            print(f"  UNJUDGED {module} -- pruning pre-filter refused; not counted either way")
        elif rc3 != 0:
            findings.append(f"pruning pre-filter ({module}) rc={rc3}")
            for line in out3.splitlines():
                if "DEAD_OUTPUT_NET" in line or "INSTANCE " in line:
                    print(f"  {line.strip()}")

    if not args.elaboration_evidence:
        print("STEP3_SURVIVES_SYNTHESIS unmeasured")
        print(
            "FIT_READINESS_UNSCORED: no Analysis & Synthesis evidence was supplied, so "
            "the only question that has ever caught failure mode 3 is unanswered. "
            "A missing measurement is not a passing one. Ask W-FIT-O5 for "
            "scripts/check_prefit_elaboration.sh (~4m23s), then pass "
            "--elaboration-evidence and --evidence-commit.",
            file=sys.stderr,
        )
        if findings:
            print("  cheap steps already failing: " + "; ".join(findings), file=sys.stderr)
        return UNSCORED

    measured = rtl_tree_hash(args.evidence_commit)
    current = rtl_tree_hash("HEAD")
    dirty = dirty_rtl()
    print(f"EVIDENCE_BINDING measured_tree={measured[:12]} current_tree={current[:12]} "
          f"uncommitted_rtl_changes={len(dirty)}")
    if measured != current:
        findings.append(
            f"step 3 evidence was measured on a different {RTL_SUBTREE} tree "
            f"({measured[:12]} vs {current[:12]})"
        )
    if dirty:
        findings.append(
            f"{len(dirty)} uncommitted change(s) under {RTL_SUBTREE}; the A&S run "
            "cannot have seen them"
        )
        for line in dirty[:5]:
            print(f"  DIRTY {line.strip()}")

    for module in modules:
        verdict, detail = parse_elaboration_evidence(text, module)
        print(f"STEP3_SURVIVES_SYNTHESIS {module} {verdict} {detail}".rstrip())
        if verdict != "PRESENT":
            findings.append(f"step 3 ({module}) {verdict}: {detail}")

    if findings:
        print("FIT_READINESS_NOT_READY: " + "; ".join(findings), file=sys.stderr)
        print("  No fit may be requested until every step above is green on this "
              "exact tree.", file=sys.stderr)
        return NOT_READY

    print(f"FIT_READINESS_READY modules={len(modules)} "
          f"tree={current[:12]} evidence={evidence_path.name}")
    print("  Ready to REQUEST a fit. Authorization remains the parent's and the "
          "Quartus slot remains W-FIT-O5's.")
    return READY


if __name__ == "__main__":
    raise SystemExit(main())
