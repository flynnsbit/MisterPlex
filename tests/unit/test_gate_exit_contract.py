#!/usr/bin/env python3
"""Red/green for the three-state gate exit contract.

    0 evaluated and passed | 1 evaluated and failed | 77 could not evaluate

The defect is print/exit divergence: a gate detects that it cannot evaluate,
says so in text, and exits 0 anyway. The text lands in a log nobody greps; the
exit code is what every wrapper, Makefile and CI step reads.

The anchor cases are not synthetic. `check_fitted_line_buffer.py` at
`9043925^` on `origin/w-arm-idle-edge` is the measured instance -- it printed
`UNBOUND: no --expect-rbf-md5 given` and then `LINE_BUFFER_OK` with rc=0 -- and
`9043925` is its fix. The detector must fail the first and clear the second. It
did neither until three defects in the detector itself were fixed, so these
anchors are the only reason this gate is not decorative.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "check_gate_exit_contract.py"
ANCHOR_REF = "origin/w-arm-idle-edge"
ANCHOR_FILE = "scripts/check_fitted_line_buffer.py"
ANCHOR_FIX = "9043925"


def scratch():
    base = ROOT / "build" / "w-gate-o5-scratch"
    base.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="exitcontract-", dir=str(base))


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(GATE), *args],
                          capture_output=True, text=True, cwd=ROOT)


def gate_dir(td: str, body: str, name: str = "check_probe.py") -> str:
    Path(td, name).write_text(body)
    return td


def case_announce_then_return_zero_is_divergent() -> None:
    body = '''import sys
def main():
    print("UNBOUND: no --expect-rbf-md5 given")
    return 0
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "DIVERGENT check_probe.py" in proc.stdout, proc.stdout
        assert "GATE_EXIT_CONTRACT_FAIL" in proc.stderr, proc.stderr


def case_seventy_seven_conforms() -> None:
    body = '''import sys
def main():
    print("UNBOUND: no --expect-rbf-md5 given")
    return 77
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "GATE_EXIT_CONTRACT_OK" in proc.stdout, proc.stdout


def case_status_variable_left_at_zero_is_divergent() -> None:
    """The measured shape: rc=0 early, an inability branch that never touches it."""
    body = '''def main(bound):
    rc = 0
    if bound:
        print("BOUND ok")
    else:
        print("UNBOUND: no --expect-rbf-md5 given")
    print("PROBE_OK" if rc == 0 else "PROBE_FAIL")
    return rc
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "leaves rc=0" in proc.stdout, proc.stdout


def case_sibling_branch_assignment_does_not_exonerate() -> None:
    """An `rc = 1` on a path the announcement never takes must not clear it."""
    body = '''def main(bound):
    rc = 0
    if not bound:
        print("BINDING_FAIL mismatch")
        rc = 1
    else:
        print("UNBOUND: no expectation given")
    return rc
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "DIVERGENT" in proc.stdout, proc.stdout


def case_enclosing_block_disposition_counts() -> None:
    """Regression: examining only the innermost block produced a false red."""
    body = '''def main(findings):
    if findings:
        for item in findings:
            print(f"SKIP: {item} could not be measured")
        return 1
    print("PROBE_OK")
    return 0
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body), "--show-ok")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "CONTRACT_OK" in proc.stdout, proc.stdout
        assert "DIVERGENT" not in proc.stdout, proc.stdout


def case_verdict_tokens_are_not_announcements() -> None:
    """Regression: `SKIP_EXIT_CODE_OK` is a PASS, not a skip announcement."""
    body = '''def main():
    print("SKIP_EXIT_CODE_OK files=93 skip_dominated=0")
    return 0
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        # No inability sites at all in this directory -> refuse, not fail.
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "no inability sites found" in proc.stderr, proc.stderr


def case_metric_keys_are_not_announcements() -> None:
    body = '''def main():
    print("POLICY_OK readers=4 unbound=0")
    return 0
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        assert proc.returncode == 2, proc.stdout + proc.stderr


def case_named_exit_constant_resolves() -> None:
    body = '''SKIP = 77
def main():
    print("SKIP-NOT-PASS: no fit exists yet")
    raise SystemExit(SKIP)
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body), "--show-ok")
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "exits SKIP=77" in proc.stdout, proc.stdout


def case_named_exit_constant_zero_is_divergent() -> None:
    body = '''OK = 0
def main():
    print("UNSCORED: nothing to measure")
    raise SystemExit(OK)
'''
    with scratch() as td:
        proc = run("--scripts-dir", gate_dir(td, body))
        assert proc.returncode == 1, proc.stdout + proc.stderr


def case_empty_scan_refuses() -> None:
    with scratch() as td:
        Path(td, "unrelated.py").write_text("x = 1\n")
        proc = run("--scripts-dir", td)
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert proc.stdout.startswith("Scope: "), proc.stdout


def anchor_available() -> bool:
    probe = subprocess.run(["git", "cat-file", "-e", f"{ANCHOR_FIX}:{ANCHOR_FILE}"],
                           cwd=ROOT, capture_output=True)
    return probe.returncode == 0


def case_real_measured_defect_anchor() -> int:
    """The gate w-audit broke, and its fix, straight out of git."""
    if not anchor_available():
        return 0
    anchors = 0
    for rev, expected, label in ((f"{ANCHOR_FIX}^", 1, "pre-fix"), (ANCHOR_FIX, 0, "post-fix")):
        blob = subprocess.run(["git", "show", f"{rev}:{ANCHOR_FILE}"],
                              cwd=ROOT, capture_output=True, text=True)
        assert blob.returncode == 0, blob.stderr
        with scratch() as td:
            Path(td, "check_fitted_line_buffer.py").write_text(blob.stdout)
            proc = run("--scripts-dir", td)
            assert proc.returncode == expected, (
                f"{label} {rev} expected rc={expected}, got {proc.returncode}\n"
                f"{proc.stdout}{proc.stderr}")
            if expected == 1:
                assert "marker=UNBOUND" in proc.stdout, proc.stdout
                assert "leaves rc=0" in proc.stdout, proc.stdout
        anchors += 1
    return anchors


def main() -> int:
    cases = (
        case_announce_then_return_zero_is_divergent,
        case_seventy_seven_conforms,
        case_status_variable_left_at_zero_is_divergent,
        case_sibling_branch_assignment_does_not_exonerate,
        case_enclosing_block_disposition_counts,
        case_verdict_tokens_are_not_announcements,
        case_metric_keys_are_not_announcements,
        case_named_exit_constant_resolves,
        case_named_exit_constant_zero_is_divergent,
        case_empty_scan_refuses,
    )
    available = 2 if anchor_available() else 0
    print(f"Scope: exit_contract_cases={len(cases)} real_defect_anchors={available}/2")
    for case in cases:
        case()
    anchors = case_real_measured_defect_anchor()
    assert anchors == available, (anchors, available)
    print(f"GATE_EXIT_CONTRACT_TEST_OK cases={len(cases)} real_anchors={anchors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
