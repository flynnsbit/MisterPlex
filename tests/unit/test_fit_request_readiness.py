#!/usr/bin/env python3
"""Red/green for the fit-request readiness order.

The parent's revised ruling: steps 1 and 2 are necessary and jointly
insufficient -- both were green on `w-decode-hour27` `2f165ed` while
`h264_decode_core` was absent from Analysis & Synthesis -- so no fit may be
requested until step 3 shows the module PRESENT.

The two properties this suite exists to hold down:

  * **absent evidence is 77, never 0.** Every product-absence incident on this
    project began with an unasked question being treated as an answered one.
  * **evidence is bound to the tree it was measured on.** A&S evidence from
    commit X must not license a fit of commit Y, and uncommitted RTL edits
    invalidate it because the A&S run cannot have seen them.

The green arm is driven in-process with the sibling gates stubbed, because a
real READY needs a tree where the decoder actually survives synthesis -- which
is the thing the fleet is still working towards. Stubbing is declared rather
than hidden: what is being tested here is the *ordering and binding logic*, not
the sibling gates, which have their own suites.
"""
from __future__ import annotations

import contextlib
import io
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_fit_request_readiness as fr  # noqa: E402

GATE = ROOT / "scripts" / "check_fit_request_readiness.py"

PRESENT_EVIDENCE = """Scope: 827 entity rows parsed from Plex.map.rpt [map]
required modules: 1
PRESENT h264_decode_core instances=1 subtree_rows=61
PREFIT_HIERARCHY_OK required=1 rows=827
"""

ABSENT_EVIDENCE = """Scope: 827 entity rows parsed from Plex.map.rpt [map]
required modules: 1
ABSENT h264_decode_core -- ELABORATED_BUT_OPTIMIZED_AWAY
    elaborated_as: emu:emu|stream_path:spath|h264_decode_core:product_decode_core
PREFIT_HIERARCHY_FAIL required=1 rows=827
"""

REFUSED_EVIDENCE = """Scope: 0 entity rows parsed from nothing.rpt [map]
REFUSED: Scope: 0 entity rows -- a PASS cannot be claimed
"""


def scratch():
    base = ROOT / "build" / "w-gate-o5-scratch"
    base.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="fitready-", dir=str(base))


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(GATE), *args], capture_output=True, text=True, cwd=ROOT
    )


def call_main(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = fr.main(argv)
    except SystemExit as exc:
        rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


def case_no_evidence_is_unscored_not_green() -> None:
    proc = run()
    assert proc.returncode == 77, proc.stdout + proc.stderr
    assert proc.stdout.splitlines()[0].startswith("Scope: "), proc.stdout
    assert "STEP3_SURVIVES_SYNTHESIS unmeasured" in proc.stdout, proc.stdout
    assert "missing measurement is not a passing one" in proc.stderr, proc.stderr


def case_missing_evidence_file_is_refused() -> None:
    proc = run("--elaboration-evidence", "build/w-gate-o5-scratch/does-not-exist.log")
    assert proc.returncode == 2, proc.stdout + proc.stderr
    # Exactly one Scope line per run, and operator error is refused before any
    # step verdict is printed -- a malformed request is not a finding.
    assert proc.stdout.count("Scope: ") == 1, proc.stdout
    assert "EVIDENCE_UNUSABLE not_found" in proc.stdout, proc.stdout
    assert "STEP1_COMPILED" not in proc.stdout, proc.stdout


def case_empty_evidence_is_refused() -> None:
    with scratch() as td:
        path = Path(td) / "empty.log"
        path.write_text("   \n")
        proc = run("--elaboration-evidence", str(path))
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "empty evidence" in proc.stderr, proc.stderr
        assert "EVIDENCE_UNUSABLE empty" in proc.stdout, proc.stdout


def case_unbound_evidence_is_refused() -> None:
    """Evidence without a commit is how one tree's measurement licenses another."""
    with scratch() as td:
        path = Path(td) / "present.log"
        path.write_text(PRESENT_EVIDENCE)
        proc = run("--elaboration-evidence", str(path))
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "--evidence-commit" in proc.stderr, proc.stderr


def case_absent_module_is_not_ready() -> None:
    with scratch() as td:
        path = Path(td) / "absent.log"
        path.write_text(ABSENT_EVIDENCE)
        proc = run("--elaboration-evidence", str(path), "--evidence-commit", "HEAD")
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "ELABORATED_BUT_OPTIMIZED_AWAY" in proc.stdout, proc.stdout


def case_stale_evidence_is_not_ready() -> None:
    """Same module PRESENT, but measured on a different fpga/ tree."""
    older = subprocess.run(
        ["git", "rev-list", "-n", "40", "HEAD"], capture_output=True, text=True, cwd=ROOT
    ).stdout.split()
    stale = None
    current = fr.rtl_tree_hash("HEAD")
    for commit in older:
        if fr.rtl_tree_hash(commit) not in (None, current):
            stale = commit
            break
    if stale is None:
        return  # no commit in range touched fpga/; nothing to assert
    with scratch() as td:
        path = Path(td) / "present.log"
        path.write_text(PRESENT_EVIDENCE)
        proc = run("--elaboration-evidence", str(path), "--evidence-commit", stale)
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "EVIDENCE_BINDING" in proc.stdout, proc.stdout
        assert "different fpga/Plex_MiSTer tree" in proc.stderr, proc.stderr


def case_present_and_bound_is_ready() -> None:
    """Green arm, with the sibling gates stubbed and that fact declared."""
    with scratch() as td:
        path = Path(td) / "present.log"
        path.write_text(PRESENT_EVIDENCE)
        saved_run, saved_dirty = fr.run_gate, fr.dirty_rtl
        fr.run_gate = lambda argv: (0, "stubbed OK")
        fr.dirty_rtl = lambda: []
        try:
            rc, out, err = call_main(
                ["--elaboration-evidence", str(path), "--evidence-commit", "HEAD"]
            )
        finally:
            fr.run_gate, fr.dirty_rtl = saved_run, saved_dirty
        assert rc == 0, (out, err)
        assert "FIT_READINESS_READY" in out, out
        assert "STEP3_SURVIVES_SYNTHESIS h264_decode_core PRESENT" in out, out
        assert "Authorization remains the parent's" in out, out


def case_dirty_rtl_invalidates_evidence() -> None:
    with scratch() as td:
        path = Path(td) / "present.log"
        path.write_text(PRESENT_EVIDENCE)
        saved_run, saved_dirty = fr.run_gate, fr.dirty_rtl
        fr.run_gate = lambda argv: (0, "stubbed OK")
        fr.dirty_rtl = lambda: [" M fpga/Plex_MiSTer/rtl/stream_path.sv"]
        try:
            rc, out, err = call_main(
                ["--elaboration-evidence", str(path), "--evidence-commit", "HEAD"]
            )
        finally:
            fr.run_gate, fr.dirty_rtl = saved_run, saved_dirty
        assert rc == 1, (out, err)
        assert "uncommitted change" in err, err
        assert "cannot have seen them" in err, err


def case_evidence_parser_classifies_all_four() -> None:
    assert fr.parse_elaboration_evidence(PRESENT_EVIDENCE, "h264_decode_core")[0] == "PRESENT"
    assert fr.parse_elaboration_evidence(ABSENT_EVIDENCE, "h264_decode_core")[0] == "ABSENT"
    assert fr.parse_elaboration_evidence(REFUSED_EVIDENCE, "h264_decode_core")[0] == "REFUSED"
    verdict, detail = fr.parse_elaboration_evidence(PRESENT_EVIDENCE, "h264_inter_mc_16x16")
    assert verdict == "NOT_MENTIONED", (verdict, detail)


def case_substring_module_name_is_not_a_match() -> None:
    """PRESENT h264_decode_core must not answer for h264_decode_core_v2."""
    verdict, _ = fr.parse_elaboration_evidence(PRESENT_EVIDENCE, "h264_decode_core_v2")
    assert verdict == "NOT_MENTIONED", verdict


def case_cheap_gates_warn_they_cannot_see_optimize_away() -> None:
    """The parent's second instruction: the two cheap gates must say they are blind."""
    for script in ("check_qip_coverage.py", "check_rtl_module_instantiations.py"):
        proc = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / script)],
            capture_output=True, text=True, cwd=ROOT,
        )
        assert proc.returncode == 0, (script, proc.stdout, proc.stderr)
        assert "NOT_A_SURVIVAL_CLAIM" in proc.stdout, (script, proc.stdout)
        assert "check_prefit_elaboration.sh" in proc.stdout, (script, proc.stdout)


def main() -> int:
    cases = (
        case_no_evidence_is_unscored_not_green,
        case_missing_evidence_file_is_refused,
        case_empty_evidence_is_refused,
        case_unbound_evidence_is_refused,
        case_absent_module_is_not_ready,
        case_stale_evidence_is_not_ready,
        case_present_and_bound_is_ready,
        case_dirty_rtl_invalidates_evidence,
        case_evidence_parser_classifies_all_four,
        case_substring_module_name_is_not_a_match,
        case_cheap_gates_warn_they_cannot_see_optimize_away,
    )
    print(f"Scope: fit_readiness_cases={len(cases)}")
    for case in cases:
        case()
    print(f"FIT_READINESS_GATE_TEST_OK cases={len(cases)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
