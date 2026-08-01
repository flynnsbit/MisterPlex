#!/usr/bin/env python3
"""Static guard: absence-of-evidence must not collapse to measured zero.

Flags active (non-comment) patterns:
  grep -c ... || true
  grep -c ... || echo 0
  pidof <daemon> (misterplexd process identity)
  build_rbf_remote STA count without hard-fail path

Exit 0 clean, 1 findings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# High-value scripts that must not collapse counts / use pidof for misterplexd.
SCAN = [
    "scripts/build_rbf_remote.sh",
    "scripts/measure_c2_pixel_path.sh",
    "scripts/deploy_misterplexd.sh",
    "scripts/deploy_plex_core.sh",
    "scripts/plexctl.sh",
    "scripts/misterplexd_supervise.sh",
    "scripts/video_regression.sh",
    "scripts/restore_misterplexd_prev.sh",
    "scripts/source_rate_rca.sh",
    "scripts/validate_playback_controls_hw.sh",
    "tests/hw/test_idle_screen_telemetry.sh",
    "tests/hw/test_bank_release_visual.sh",
    "tests/hw/test_p480_ab_harness.sh",
]

GREP_C_COLLAPSE = re.compile(
    r"grep\s+-c[^\n]*\|\|\s*(true|echo\s+0)",
    re.IGNORECASE,
)
PIDOF_DAEMON = re.compile(r"\bpidof\s+misterplexd\b")


def code_lines(text: str) -> list[str]:
    out = []
    for ln in text.splitlines():
        s = ln.lstrip()
        if s.startswith("#"):
            continue
        out.append(ln)
    return out


def main() -> int:
    errs: list[str] = []

    for rel in SCAN:
        path = ROOT / rel
        if not path.is_file():
            continue
        text = path.read_text(errors="ignore")
        code = "\n".join(code_lines(text))
        for m in GREP_C_COLLAPSE.finditer(code):
            # allow in measure_status banned doc strings
            if "BANNED" in text[max(0, m.start() - 200) : m.start()]:
                continue
            errs.append(f"{rel}: grep -c collapsed with || {m.group(1)} (absence→zero)")
        if PIDOF_DAEMON.search(code):
            errs.append(f"{rel}: pidof misterplexd (use /proc/PID/exe basename; deleted-tolerant)")

    br = (ROOT / "scripts/build_rbf_remote.sh").read_text(errors="ignore")
    if "STA_ABSENT_OR_UNREADABLE" not in br and "sta_absent_or_unreadable" not in br:
        errs.append("build_rbf_remote: missing STA absent hard-fail marker")
    if "measure_sta_neg_slack" not in br and "MEASURE_STATUS" not in br:
        # remote path may inline the check
        if "sta_absent_or_unreadable" not in br:
            errs.append("build_rbf_remote: STA path must use three-way measure")

    sup = (ROOT / "scripts/misterplexd_supervise.sh").read_text(errors="ignore")
    if re.search(r"trap\s+'[^']*exit 0'", sup):
        errs.append("misterplexd_supervise: trap still exits 0 on signal")
    if "SUPERVISE_SIGNAL" not in sup:
        errs.append("misterplexd_supervise: missing SUPERVISE_SIGNAL log")

    pct = (ROOT / "scripts/plexctl.sh").read_text(errors="ignore")
    if "SUPERVISE_SIGNAL" not in pct:
        errs.append("plexctl: supervisor template missing SUPERVISE_SIGNAL")
    if re.search(r"trap\s+'[^']*exit 0'\s+TERM", pct):
        errs.append("plexctl: trap still exits 0 on TERM")

    # restore_misterplexd_prev must stay hard-refuse (not half-restore with pidof)
    rest = (ROOT / "scripts/restore_misterplexd_prev.sh").read_text(errors="ignore")
    if "HALF_RESTORE" not in rest and "exit 10" not in rest:
        errs.append("restore_misterplexd_prev: must hard-refuse half restore")

    if not (ROOT / "scripts/lib/measure_status.inc.sh").is_file():
        errs.append("missing scripts/lib/measure_status.inc.sh")

    if errs:
        print(f"ABSENCE_AS_ZERO findings={len(errs)}")
        for e in errs:
            print(f"  FIND {e}")
        print("true rc=1")
        return 1
    print("ABSENCE_AS_ZERO_STATIC OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
