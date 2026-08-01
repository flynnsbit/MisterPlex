#!/usr/bin/env python3
"""Instrument premise-before-PASS guard (parent soak 2026-08-01).

Confirmed defect: publish_swap_delta emitted skip_verdict=NO_ZERO_REFRESH_SKIP
while p_dge2≈0.97 — premise Δframes_done∈{0,1} with Δ=1 norm was false
because c5382bee packs bank_vsync_count into PLXD frames_done.

Rules locked here:
  1) skip_verdict PASS-class strings require fd_semantics=SWAP_COUNTER premise
  2) vsync-packed synthetic series → skip_verdict=UNSCORED (RBG via unit binary)
  3) FRAME_LEDGER must declare scope=ARM_PUBLISH_NOT_DISPLAY (not PLXD circular)
  4) deploy must fail-fast on missing policy deps (rc=2), never after overall=0

true rc: cmd; echo "true rc=$?"
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWAP_HPP = ROOT / "host/libmisterplex/publish_swap_delta_ledger.hpp"
LEDGER_HPP = ROOT / "host/libmisterplex/frame_ledger.hpp"
LEDGER_CPP = ROOT / "host/libmisterplex/frame_ledger.cpp"
DEPLOY = ROOT / "scripts/deploy_misterplexd.sh"
BACKUP = ROOT / "scripts/daemon_backup_policy.sh"
SWAP_TEST = ROOT / "tests/unit/test_publish_swap_delta_ledger.cpp"
SWAP_BIN = ROOT / "build/test_publish_swap_delta_ledger"


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def audit_static() -> list[str]:
    errs: list[str] = []

    if not SWAP_HPP.is_file():
        errs.append("MISSING publish_swap_delta_ledger.hpp")
        return errs
    sh = _read(SWAP_HPP)
    if "LIKELY_VSYNC_PACKED" not in sh:
        errs.append("swap ledger: missing LIKELY_VSYNC_PACKED classification")
    if "p_delta1 < 0.5" not in sh and "p_delta1<" not in sh.replace(" ", ""):
        errs.append("swap ledger: missing p_delta1 premise gate")
    if 'skip_verdict = "UNSCORED"' not in sh and "skip_verdict = \"UNSCORED\"" not in sh:
        # allow either quote style
        if "UNSCORED" not in sh or "skip_verdict" not in sh:
            errs.append("swap ledger: missing UNSCORED skip path")
    # Must not assign NO_ZERO before premise (crude: NO_ZERO only after SWAP_COUNTER)
    # Find NO_ZERO assignment block context
    if "NO_ZERO_REFRESH_SKIP" in sh:
        # require fd_semantics SWAP_COUNTER near skip assignment path
        if "SWAP_COUNTER" not in sh:
            errs.append("swap ledger: NO_ZERO_REFRESH_SKIP without SWAP_COUNTER path")
        # ensure ge2 path forces unscored
        if "p_delta_ge2" not in sh:
            errs.append("swap ledger: no p_delta_ge2 tracking")

    if not LEDGER_HPP.is_file():
        errs.append("MISSING frame_ledger.hpp")
    else:
        lh = _read(LEDGER_HPP)
        if "ARM_PUBLISH_NOT_DISPLAY" not in lh:
            errs.append("frame_ledger.hpp: missing scope=ARM_PUBLISH_NOT_DISPLAY")
        if "do NOT read PLXD" not in lh and "NOT read PLXD" not in lh:
            errs.append("frame_ledger.hpp: missing PLXD non-circularity note")
        # Must document presents = presentCount_
        if "presentCount_" not in lh:
            errs.append("frame_ledger.hpp: must document presents=presentCount_")

    if LEDGER_CPP.is_file():
        lc = _read(LEDGER_CPP)
        if "ARM_PUBLISH_NOT_DISPLAY" not in lc:
            errs.append("frame_ledger.cpp: session_end missing scope tag")

    if not DEPLOY.is_file():
        errs.append("MISSING deploy_misterplexd.sh")
    else:
        d = _read(DEPLOY)
        if "daemon_backup_policy.sh" not in d:
            errs.append("deploy: must require daemon_backup_policy.sh")
        if "boot_hook_policy.sh" not in d:
            errs.append("deploy: must reference boot_hook_policy.sh")
        if "would_false_fail_after_live_verify" not in d and "missing scripts/boot_hook_policy" not in d:
            errs.append("deploy: missing explicit boot_hook_policy existence check")
        # overall=0 must appear after boot_hook source
        lines = d.splitlines()
        overall0 = [i for i, L in enumerate(lines) if 'report_rc "deploy_overall" 0' in L]
        hook_src = [i for i, L in enumerate(lines) if "source" in L and "boot_hook_policy" in L]
        if overall0 and hook_src and min(overall0) < max(hook_src):
            errs.append(
                f"deploy: report_rc deploy_overall 0 at line {min(overall0)+1} "
                f"BEFORE boot_hook source at {max(hook_src)+1} (parent false-neg class)"
            )

    if not BACKUP.is_file():
        errs.append("MISSING scripts/daemon_backup_policy.sh (deploy dep)")

    if SWAP_TEST.is_file():
        st = _read(SWAP_TEST)
        if "vsync_packed" not in st or "UNSCORED" not in st:
            errs.append("test_publish_swap_delta_ledger: missing vsync_packed→UNSCORED case")
    else:
        errs.append("MISSING test_publish_swap_delta_ledger.cpp")

    return errs


def run_swap_unit() -> tuple[int, str]:
    if not SWAP_BIN.is_file():
        # build
        SWAP_BIN.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(
            [
                "g++",
                "-std=c++17",
                "-O0",
                "-I" + str(ROOT / "host"),
                "-o",
                str(SWAP_BIN),
                str(SWAP_TEST),
            ],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            return r.returncode, "BUILD_FAIL\n" + r.stderr
    r = subprocess.run([str(SWAP_BIN)], cwd=str(ROOT), capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def run_self_test() -> int:
    errs = audit_static()
    if errs:
        print("STATIC_FAIL")
        for e in errs:
            print(" ", e)
        return 1
    print("STATIC_OK instrument_premise_guard")

    rc, out = run_swap_unit()
    print(out)
    if rc != 0:
        print("SWAP_UNIT_FAIL")
        return 1
    if "vsync_packed" in out and "skip_verdict=UNSCORED" not in out:
        # format line should contain unscored
        if "LIKELY_VSYNC_PACKED" not in out:
            print("SWAP_UNIT_MISS vsync classification")
            return 1
    if "NO_ZERO_REFRESH_SKIP" in out and "healthy" in out:
        print("RBG_OK healthy can still claim NO_ZERO under SWAP_COUNTER")
    print("SWAP_UNIT_OK")
    print("SELFTEST_OK instrument_premise_guard")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = argv or sys.argv[1:]
    if "--self-test" in argv:
        rc = run_self_test()
        print(f"true rc={rc}")
        return rc
    findings = audit_static()
    print("INSTRUMENT_PREMISE_BEGIN")
    print(f"findings={len(findings)}")
    for f in findings:
        print(f"FIND {f}")
    print("INSTRUMENT_PREMISE_END")
    if findings:
        print("INSTRUMENT_PREMISE_FAIL")
        print("true rc=1")
        return 1
    # also run unit binary if present
    rc, out = run_swap_unit()
    if rc != 0:
        print(out)
        print("INSTRUMENT_PREMISE_FAIL swap_unit")
        print(f"true rc={rc}")
        return rc
    print("INSTRUMENT_PREMISE_OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
