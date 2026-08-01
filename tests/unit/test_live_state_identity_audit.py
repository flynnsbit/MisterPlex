#!/usr/bin/env python3
"""Audit high-risk scripts for disk/name/cache identity disease.

Rule: promotion-critical gates must not treat on-disk md5 or CORENAME alone as
proof of the RUNNING bitstream/daemon. This is a static contract check with
known allow/deny patterns — not a runtime hardware probe.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Scripts that MUST demonstrate live-state awareness (positive contract).
REQUIRED = {
    "scripts/video_regression.sh": [
        r"/proc/.*/exe",
        r"RUNNING_CORE|running_core_claim|RUNNING_CORE_IDENTITY",
        r"NO-DATA",
        r"pair-mismatch|pair_coherent",
        r"argv0",
    ],
    "scripts/plexctl.sh": [
        r"running_core_claim|write_running_core_claim",
        r"RBFNAME.*mtime|rbfname_mtime",
    ],
}

# High-risk anti-patterns in gate/verify scripts (not every deploy helper).
GATE_GLOBS = [
    "scripts/video_regression.sh",
    "tests/hw/test_idle_screen_telemetry.sh",
    "tests/hw/test_f3_visual_golden.sh",
    "tests/hw/test_p480_ab_harness.sh",
]

# Patterns that are disease *if* they appear as sole identity without live markers nearby.
# We flag files that use CORENAME as success identity without claim/PLXC/mtime language.
DISEASE_CORENAME_AS_ID = re.compile(
    r"grep\s+-qi?\s+plex.*/tmp/CORENAME|CORENAME.*grep.*plex", re.I
)
LIVE_MARKERS = re.compile(
    r"running_core_claim|RUNNING_CORE|PLXC|RBFNAME_MTIME|rbfname_mtime|/proc/.*/exe|pair-coherent",
    re.I,
)

# pidof misterplexd as sole process identity in gates (false friends with flock).
PIDOF_DAEMON = re.compile(r"pidof\s+misterplexd")


def main() -> int:
    rc = 0
    for rel, pats in REQUIRED.items():
        path = ROOT / rel
        if not path.is_file():
            print(f"FAIL missing required gate script {rel}")
            rc = 1
            continue
        text = path.read_text(errors="replace")
        for pat in pats:
            if not re.search(pat, text):
                print(f"FAIL {rel}: missing required live-state pattern /{pat}/")
                rc = 1
            else:
                print(f"OK   {rel}: has /{pat}/")

    # video_regression must not accept empty as FAIL mismatch wording as primary path
    vr = (ROOT / "scripts/video_regression.sh").read_text(errors="replace")
    if "NO-DATA" not in vr or "not a mismatch" not in vr:
        print("FAIL video_regression.sh missing NO-DATA empty-hash contract")
        rc = 1
    else:
        print("OK   video_regression.sh NO-DATA contract present")

    if "VIDREG_REQUIRE_CORE_ID" not in vr or "RED_SPI_DAEMON_DDR_CORE" not in vr:
        print("FAIL video_regression.sh missing VIDREG_CORE_ID / RED_SPI_DAEMON_DDR_CORE contract")
        rc = 1
    else:
        print("OK   video_regression.sh VIDREG_CORE_ID contract present")

    if "GATE_CORE_IDENTITY=UNVERIFIED" not in vr and "RUNNING_CORE_IDENTITY" not in vr:
        print("FAIL video_regression.sh missing UNVERIFIED identity stamp")
        rc = 1
    else:
        print("OK   video_regression.sh UNVERIFIED identity stamp present")

    # DDR CURRENT tracks validated-pair (865d4c8a); edc3a46b is PREV CURRENT; e9f79de2 hist.
    if "pair_pin_resolve" not in vr and "validated-pair" not in vr:
        print("FAIL video_regression must resolve pins via validated-pair/pair_pin")
        rc = 1
    else:
        print("OK   video_regression validated-pair pin resolve")
    if "865d4c8a" not in vr:
        print("FAIL CURRENT daemon pin 865d4c8a missing from video_regression")
        rc = 1
    else:
        print("OK   CURRENT pin 865d4c8a present")
    if "PREV_CURRENT_DDR_DAEMON_MD5=edc3a46b" not in vr and "edc3a46b" not in vr:
        print("FAIL PREV CURRENT edc3a46b missing")
        rc = 1
    else:
        print("OK   PREV CURRENT edc3a46b retained")
    if not re.search(r"PREV_DDR_DAEMON_MD5=e9f79de2", vr):
        print("FAIL PREV_DDR_DAEMON_MD5 missing e9f79de2 rollback pin")
        rc = 1
    else:
        print("OK   PREV_DDR_DAEMON_MD5=e9f79de2")
    # (deleted)-tolerant exe identity required
    if '(deleted)' not in vr and "deleted" not in vr:
        print("FAIL video_regression missing (deleted) exe tolerance")
        rc = 1
    else:
        print("OK   video_regression (deleted) tolerance")

    # Audit siblings: report findings (WARN does not fail unit unless GATE file
    # uses CORENAME as sole identity without live markers).
    for rel in GATE_GLOBS:
        path = ROOT / rel
        if not path.is_file():
            continue
        text = path.read_text(errors="replace")
        has_corename_id = bool(DISEASE_CORENAME_AS_ID.search(text))
        has_live = bool(LIVE_MARKERS.search(text))
        has_pidof = bool(PIDOF_DAEMON.search(text))
        if has_corename_id and not has_live and rel != "scripts/video_regression.sh":
            print(f"WARN {rel}: CORENAME used as identity without claim/PLXC/live markers")
            # idle/f3 tests: informational — parent-owned HW; do not hard-fail unit
        if has_pidof and rel == "tests/hw/test_idle_screen_telemetry.sh":
            print(f"WARN {rel}: uses pidof misterplexd (prefer argv0 + /proc/PID/exe)")
        if has_corename_id and has_live:
            print(f"OK   {rel}: CORENAME present but live markers also present")

    if rc == 0:
        print("ALL test_live_state_identity_audit checks passed")
    return rc


if __name__ == "__main__":
    sys.exit(main())
