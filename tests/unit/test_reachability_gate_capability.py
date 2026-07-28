#!/usr/bin/env python3
"""Red/green for the reachability-gate capability probe.

The probe's job is to refuse `--root`/`--require` evidence from a checker that
cannot honour those flags. W-FIT-O5 measured that exact situation on
`parent/integ-hour27`, where a 200-line variant with no argument parser answers
the plain masked `emu` question, prints `root=emu` while you asked for
`h264_decode_core`, and exits 0.

This suite uses **synthetic** stand-in checkers so it does not depend on any
other worktree existing, and covers the specific trap that the probe's first
draft fell into: scoring a degraded checker as OK because it happened to exit
non-zero for an unrelated reason.
"""
from __future__ import annotations

import contextlib
import io
import os
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_reachability_gate_capability as cap  # noqa: E402

SCRATCH = ROOT / "build" / "gate-capability-cases"


def write_checker(name: str, body: str) -> Path:
    """Place a stand-in checker so that `parents[1]` is a real directory."""
    case = SCRATCH / name / "scripts"
    case.mkdir(parents=True, exist_ok=True)
    path = case / "check_rtl_module_instantiations.py"
    path.write_text("#!/usr/bin/env python3\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def run(checker: Path) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cap.main(["--checker", str(checker)])
    except SystemExit as exc:
        rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


CAPABLE = """
import argparse, sys
ap = argparse.ArgumentParser()
ap.add_argument("--root", default="emu")
ap.add_argument("--require", action="append", default=[])
ap.add_argument("--allow-non-product-root", action="store_true")
a = ap.parse_args()
if a.root != "emu":
    print(f"--root names a module that does not exist: {a.root}", file=sys.stderr)
    raise SystemExit(1)
print("Scope: rtl_modules=1")
print("UNDECIDABLE_GENERATE_MODULES count=0 <none>")
print("TRUNK_PROOF emu path=emu hops=0 via_masking_lineage=no")
"""

NO_ARGPARSE = """
print("RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=44 bench_only=24 root=emu")
"""

NONZERO_FOR_UNRELATED_REASON = """
import sys
print("missing explicit NONDEFAULT_CONFIG_REACHABLE list", file=sys.stderr)
raise SystemExit(1)
"""


def case_capable_passes() -> None:
    rc, out, err = run(write_checker("capable", CAPABLE))
    assert rc == 0, (out, err)
    assert "REACHABILITY_GATE_CAPABLE probes=4" in out, out
    assert out.startswith("Scope: reachability_capability_probes=4"), out


def case_no_argparse_is_caught() -> None:
    """The variant W-FIT-O5 measured: ignores every flag, exits 0, looks green."""
    rc, out, err = run(write_checker("no_argparse", NO_ARGPARSE))
    assert rc == 1, out
    assert "REACHABILITY_GATE_DEGRADED rejects_unknown_flag" in err, err
    assert "REACHABILITY_GATE_DEGRADED bad_root_is_fatal" in err, err
    assert "PROBE rejects_unknown_flag FAIL" in out, out


def case_nonzero_for_unrelated_reason_is_not_evidence() -> None:
    """The trap this probe's own first draft fell into.

    A checker that dies with rc=1 because a branch-state manifest is missing has
    still not demonstrated that it parses arguments. Scoring that as OK is
    exactly `rc != 0` for an unexamined reason -- the same vacuity class the gate
    exists to hunt.
    """
    checker = write_checker("unrelated_failure", NONZERO_FOR_UNRELATED_REASON)
    problem = cap.probe_rejects_unknown_flag(checker)
    assert problem is not None, (
        "a non-zero exit without an argument-parser diagnostic must not count as "
        "proof that the flag was rejected"
    )
    assert "without an argument-parser diagnostic" in problem, problem
    rc, _out, err = run(checker)
    assert rc == 1, "an unassessable checker must not pass"
    assert "REACHABILITY_GATE_DEGRADED" in err, err


def case_missing_checker_is_fatal_not_skipped() -> None:
    rc, _out, err = run(SCRATCH / "nowhere" / "scripts" / "check_rtl_module_instantiations.py")
    assert rc == 1, "a missing structural gate is a hard fail, never an UNSCORED skip"
    assert rc != 77, "77 is for what is truly unmeasurable, not for an absent gate"
    assert "missing entirely" in err, err


def case_runs_checker_in_its_own_tree() -> None:
    """Manifests are branch state; a foreign copy must not be run from here."""
    checker = write_checker("cwd_probe", "import os; print('CWD', os.getcwd())")
    _rc, out = cap.run(checker, [])
    assert str(checker.resolve().parents[1]) in out, (
        "the checker must run with its own repo root as cwd, or branch-state "
        f"manifests produce a phantom failure: {out.strip()!r}"
    )


def main() -> int:
    cases = [
        case_capable_passes,
        case_no_argparse_is_caught,
        case_nonzero_for_unrelated_reason_is_not_evidence,
        case_missing_checker_is_fatal_not_skipped,
        case_runs_checker_in_its_own_tree,
    ]
    print(f"Scope: gate_capability_cases={len(cases)} probes={len(cap.PROBES)}", flush=True)
    assert cases, "Scope: 0 cannot claim a PASS"
    for case in cases:
        case()
    print(f"GATE_CAPABILITY_TEST_OK cases={len(cases)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
