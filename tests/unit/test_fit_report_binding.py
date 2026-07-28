#!/usr/bin/env python3
"""Red/green for report->bitstream binding and the policy that mandates it.

`w-arm-o5` found the hazard: 40 fit reports on this host by its count, 92 by
mine, and only a handful describe the build the user is running. A gate pointed
at the wrong one prints entirely true numbers about a build that does not exist.
Nothing downstream can detect it, because there is no parse error to catch.

The parent's rule: an unbound report is UNBOUND, never a pass.

Real anchors: `wfit-hour27-sdc-a` (Plex.rbf fb4bad84…) and `wfit-hour27-a`
(3b1e8435…) both carry real Quartus reports, so the bound / mismatch arms run
against genuine fitter output rather than fixtures.
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "scripts" / "check_fit_report_binding_policy.py"
TIMING = ROOT / "scripts" / "check_quartus_timing.py"
SLOTS = Path("/home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out")
RESIDENT_MD5 = "fb4bad84"
OTHER_MD5 = "3b1e8435"


def scratch():
    base = ROOT / "build" / "w-gate-o5-scratch"
    base.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix="binding-", dir=str(base))


def run(script: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(script), *args],
                          capture_output=True, text=True, cwd=ROOT)


def make_reader(path: Path, *, imports: bool, adds: bool, requires: bool) -> None:
    lines = ["import argparse"]
    if imports:
        lines.append("import fit_report_binding as binding")
    lines += ["def main():", "    ap = argparse.ArgumentParser()",
              '    ap.add_argument("--fit-rpt")']
    if adds:
        lines.append("    binding.add_binding_args(ap)")
    lines.append("    args = ap.parse_args()")
    if requires:
        lines.append("    binding.require_binding(args, args.fit_rpt)")
    lines.append("    return 0")
    path.write_text("\n".join(lines) + "\n")


def case_unbound_report_is_never_a_pass() -> None:
    with scratch() as td:
        rpt = Path(td) / "Plex.sta.rpt"
        rpt.write_text("; Slow 1100mV 85C Model Setup Summary ;\n")
        (Path(td) / "Plex.rbf").write_bytes(b"synthetic")
        proc = run(TIMING, "--sta-rpt", str(rpt))
        assert proc.returncode == 77, proc.stdout + proc.stderr
        assert "FIT_REPORT_BINDING UNBOUND" in proc.stdout, proc.stdout
        assert "no_--expect-rbf-md5" in proc.stdout, proc.stdout


def case_report_without_a_bitstream_is_unbound() -> None:
    with scratch() as td:
        rpt = Path(td) / "Plex.sta.rpt"
        rpt.write_text("; nothing ;\n")
        proc = run(TIMING, "--sta-rpt", str(rpt), "--expect-rbf-md5", "abc123")
        assert proc.returncode == 77, proc.stdout + proc.stderr
        assert "no_bitstream_beside_report" in proc.stdout, proc.stdout


def case_binding_matches_and_mismatches() -> None:
    with scratch() as td:
        rpt = Path(td) / "Plex.sta.rpt"
        rpt.write_text("; nothing ;\n")
        blob = b"synthetic-bitstream"
        (Path(td) / "Plex.rbf").write_bytes(blob)
        digest = hashlib.md5(blob).hexdigest()

        good = run(TIMING, "--sta-rpt", str(rpt), "--expect-rbf-md5", digest)
        assert good.returncode == 0, good.stdout + good.stderr
        assert "FIT_REPORT_BINDING BOUND" in good.stdout, good.stdout

        # A unique prefix is enough, as the fleet quotes 8 hex digits.
        short = run(TIMING, "--sta-rpt", str(rpt), "--expect-rbf-md5", digest[:8])
        assert short.returncode == 0, short.stdout + short.stderr

        bad = run(TIMING, "--sta-rpt", str(rpt), "--expect-rbf-md5", "deadbeef")
        assert bad.returncode == 1, bad.stdout + bad.stderr
        assert "FIT_REPORT_BINDING MISMATCH" in bad.stdout, bad.stdout


def case_explicit_rbf_overrides_the_sibling() -> None:
    with scratch() as td:
        rpt = Path(td) / "Plex.sta.rpt"
        rpt.write_text("; nothing ;\n")
        (Path(td) / "Plex.rbf").write_bytes(b"sibling")
        other = Path(td) / "elsewhere.rbf"
        other.write_bytes(b"chosen")
        digest = hashlib.md5(b"chosen").hexdigest()
        proc = run(TIMING, "--sta-rpt", str(rpt), "--rbf", str(other),
                   "--expect-rbf-md5", digest)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "elsewhere.rbf" in proc.stdout, proc.stdout


def case_policy_passes_on_the_real_scripts_dir() -> None:
    proc = run(POLICY)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "FIT_REPORT_BINDING_POLICY_OK" in proc.stdout, proc.stdout
    assert "UNBOUND_READER" not in proc.stdout, proc.stdout


def case_policy_catches_an_unbound_reader() -> None:
    with scratch() as td:
        make_reader(Path(td) / "check_new_thing.py", imports=False, adds=False, requires=False)
        proc = run(POLICY, "--scripts-dir", td)
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "UNBOUND_READER check_new_thing.py" in proc.stdout, proc.stdout
        assert "FIT_BINDING_POLICY_FAIL" in proc.stderr, proc.stderr


def case_policy_catches_imported_but_never_called() -> None:
    """Importing the helper and never honouring it is the vacuous binding."""
    with scratch() as td:
        make_reader(Path(td) / "check_lazy.py", imports=True, adds=True, requires=False)
        proc = run(POLICY, "--scripts-dir", td)
        assert proc.returncode == 1, proc.stdout + proc.stderr
        assert "missing=require_binding" in proc.stdout, proc.stdout


def case_policy_refuses_an_empty_scan() -> None:
    """No readers found means the detector broke, not that the fleet is clean."""
    with scratch() as td:
        (Path(td) / "unrelated.py").write_text("x = 1\n")
        proc = run(POLICY, "--scripts-dir", td)
        assert proc.returncode == 2, proc.stdout + proc.stderr
        assert "found no fit-report readers" in proc.stderr, proc.stderr
        assert proc.stdout.startswith("Scope: "), proc.stdout


def case_real_fit_reports_anchor() -> int:
    anchors = 0
    resident = SLOTS / "wfit-hour27-sdc-a" / "Plex.sta.rpt"
    if resident.is_file():
        bound = run(TIMING, "--sta-rpt", str(resident), "--expect-rbf-md5", RESIDENT_MD5)
        assert bound.returncode == 0, bound.stdout + bound.stderr
        assert f"rbf_md5={RESIDENT_MD5}" in bound.stdout, bound.stdout
        anchors += 1
    other = SLOTS / "wfit-hour27-a" / "Plex.sta.rpt"
    if other.is_file():
        # The exact mistake the rule exists to prevent: a real report, read
        # while believing it describes the resident build.
        wrong = run(TIMING, "--sta-rpt", str(other), "--expect-rbf-md5", RESIDENT_MD5)
        assert wrong.returncode == 1, wrong.stdout + wrong.stderr
        assert "MISMATCH" in wrong.stdout and OTHER_MD5 in wrong.stdout, wrong.stdout
        anchors += 1
    return anchors


def main() -> int:
    cases = (
        case_unbound_report_is_never_a_pass,
        case_report_without_a_bitstream_is_unbound,
        case_binding_matches_and_mismatches,
        case_explicit_rbf_overrides_the_sibling,
        case_policy_passes_on_the_real_scripts_dir,
        case_policy_catches_an_unbound_reader,
        case_policy_catches_imported_but_never_called,
        case_policy_refuses_an_empty_scan,
    )
    available = sum(
        1 for rel in ("wfit-hour27-sdc-a/Plex.sta.rpt", "wfit-hour27-a/Plex.sta.rpt")
        if (SLOTS / rel).is_file()
    )
    print(f"Scope: binding_cases={len(cases)} real_fit_report_anchors={available}/2")
    for case in cases:
        case()
    anchors = case_real_fit_reports_anchor()
    assert anchors == available, (anchors, available)
    print(f"FIT_REPORT_BINDING_TEST_OK cases={len(cases)} real_anchors={anchors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
