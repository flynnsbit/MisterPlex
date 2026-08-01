#!/usr/bin/env python3
"""Static guard: av_drift_ms / clock=av-lock must never be a lip-sync PASS/FAIL.

Parent HW 2026-07-31 (five same-config HDMI offsets; three daemon series):
  - HDMI medians clustered ~120 ms apart across identical conf/daemon/core
  - daemon mean av_drift_ms stayed ≈ -30 ms (±0.8) on all three fitted runs
  - av_drift is servo setpoint echo inside AV_PRESENT_LEAD deadband
    (host/libmisterplex/av_clock.hpp avDecide leadMs/dropMs)

Binding: only external pixel+audio instruments may judge lip-sync:
  tests/hw/avsync_measure.py, tests/hw/avsync_rate.py, tools/avsync_measure_hdmi.py

This scanner flags scripts that still pass/fail gates on av_drift or av-lock.
Exit 0 = clean. Exit 1 = findings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = (
    ROOT / "scripts",
    ROOT / "tests" / "hw",
    ROOT / "tests" / "unit",
)

# pass/fail/ok that treats daemon av telemetry as correctness
BANNED = re.compile(
    r"""(?ix)
    (?:
        \bpass\b[^\n]{0,80}\bav_drift
      | \bfail\b[^\n]{0,80}\bav_drift
      | \bpass\b[^\n]{0,80}\bav-lock
      | \bfail\b[^\n]{0,80}\bav-lock
      | \bPASS\b[^\n]{0,80}\bav_drift
      | \bFAIL\b[^\n]{0,80}\bav_drift
      | av_drift_ms[^\n]{0,40}(?:pass|PASS|ok\b|OK\b)
      | clock=av-lock[^\n]{0,40}(?:pass|PASS)
      | MAX_ABS_AV_DRIFT
    )
    """
)

# Allowlisted: this guard, docs quotes, fixture log samples, measure tools themselves
ALLOW_SUBSTR = (
    "test_av_drift_not_lipsync_pass.py",
    "avsync_measure.py",
    "avsync_rate.py",
    "avsync_measure_hdmi.py",
    "TELEMETRY_ONLY",
    "not_lip_sync",
    "NOT lip-sync",
    "not lip-sync",
)


def iter_files() -> list[Path]:
    out: list[Path] = []
    for root in SCAN_ROOTS:
        if not root.is_dir():
            continue
        for p in root.rglob("*"):
            if p.suffix in {".sh", ".py", ".inc"} and p.is_file():
                out.append(p)
    return sorted(out)


def main() -> int:
    findings: list[str] = []
    # Source contract still present (quoted for auditors)
    av = (ROOT / "host" / "libmisterplex" / "av_clock.hpp").read_text(errors="ignore")
    if "avDecide" not in av or "leadMs" not in av:
        findings.append("av_clock.hpp missing avDecide/leadMs (contract moved?)")
    if "audioBytes * 1000LL" not in av and "(audioBytes * 1000LL)" not in av:
        findings.append("av_clock.hpp audioClockMs 48000 hardcode missing — re-check")

    for path in iter_files():
        rel = path.relative_to(ROOT).as_posix()
        if rel.endswith("test_av_drift_not_lipsync_pass.py"):
            continue
        text = path.read_text(errors="ignore")
        for i, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#") and "pass" not in line.lower():
                # pure comments OK unless they claim pass
                if not re.search(r"\bpass\b.*av_drift|\bfail\b.*av_drift", line, re.I):
                    continue
            if not BANNED.search(line):
                continue
            if any(a in line for a in ALLOW_SUBSTR):
                continue
            if "TELEMETRY" in line.upper() and "NOT" in line.upper():
                continue
            # Doc/ban comments that forbid using av_drift as pass/fail
            if re.search(
                r"(?i)never\s+(pass|fail)|must\s+never|not\s+(a\s+)?(pass|lip)|"
                r"retired|do\s+not\s+(pass|fail|use)|TELEMETRY",
                line,
            ):
                continue
            findings.append(f"{rel}:{i}: AV_DRIFT_AS_LIPSYNC {line.strip()[:140]}")

    if findings:
        print(f"AV_DRIFT_LIPSYNC_GUARD findings={len(findings)}")
        for f in findings:
            print(f"  FIND {f}")
        print("true rc=1")
        return 1
    print("AV_DRIFT_LIPSYNC_GUARD clean findings=0")
    print("  NOTE lip-sync judge = external HDMI instrument only")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
