#!/usr/bin/env python3
"""Run a gate command and print a non-failing skipped-coverage summary.

The wrapped command's exit code is preserved exactly. This tool only makes
soft skips visible at the end of long logs so a green exit cannot be mistaken
for full coverage.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1, "ADVISORY": 2}


@dataclass(frozen=True)
class SkipRecord:
    name: str
    severity: str
    reason: str
    would_catch: str
    source: str


def conf_val(key: str, file_name: str | None) -> str:
    if not file_name:
        return ""
    p = Path(file_name).expanduser()
    if not p.exists():
        return ""
    for line in p.read_text(errors="ignore").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == key:
            return v.strip()
    return ""


def default_conf_file() -> str:
    env_conf = os.environ.get("MISTERPLEX_CONF") or os.environ.get("MISTER_CONF")
    if env_conf:
        return env_conf
    for candidate in (ROOT / "assets" / "misterplex.conf", Path.home() / ".config/misterplex/misterplex.conf"):
        if candidate.exists():
            return str(candidate)
    return ""


def live_pms_missing_reason() -> str:
    conf = default_conf_file()
    missing: list[str] = []
    if not (os.environ.get("PLEX_BASE") or conf_val("PLEX_BASE", conf)):
        missing.append("PLEX_BASE")
    if not (os.environ.get("PLEX_TOKEN") or conf_val("PLEX_TOKEN", conf)):
        missing.append("PLEX_TOKEN")
    if not (os.environ.get("MISTERPLEX_BASELINE_KEY") or os.environ.get("PLEX_KEY")):
        missing.append("MISTERPLEX_BASELINE_KEY")
    if shutil.which("ffmpeg") is None:
        missing.append("ffmpeg")
    return ", ".join(missing)


def registry_skips(label: str) -> list[SkipRecord]:
    skips: list[SkipRecord] = []
    if label == "make-unit":
        missing = live_pms_missing_reason()
        if missing:
            skips.append(
                SkipRecord(
                    name="live-pms-baseline-profile",
                    severity="CRITICAL",
                    reason=f"missing {missing}",
                    would_catch=(
                        "PMS drift away from the FPGA decoder contract: "
                        "Baseline profile_idc=66, CAVLC, ref=1, no B-slices, "
                        "coded 624x480/display 618x480"
                    ),
                    source="make-unit coverage inventory",
                )
            )
    return skips


def classify_skip_line(line: str) -> SkipRecord | None:
    if "SKIP-NOT-PASS" in line:
        if "pms_baseline_profile" in line or "test_pms_baseline_profile" in line:
            return SkipRecord(
                name="live-pms-baseline-profile",
                severity="CRITICAL",
                reason=line.strip(),
                would_catch=(
                    "PMS delivered-stream violations of Baseline/CAVLC/ref=1/no-B "
                    "FPGA decode contract"
                ),
                source="log",
            )
        if "pms_nal_stats" in line or "test_pms_nal_stats" in line:
            return SkipRecord(
                name="live-pms-nal-stats",
                severity="HIGH",
                reason=line.strip(),
                would_catch="live PMS NAL size/jitter drift used to size the host→FPGA bitstream ring",
                source="log",
            )
        return SkipRecord("skip-not-pass", "HIGH", line.strip(), "a named non-pass gate condition", "log")

    # Avoid counting ordinary test variable names such as SKIP_EMPTY.
    if not re.search(r"\bSKIP(?:PED)?\b", line):
        return None
    if "Verilator not found" in line or "RTL SIM" in line or "Verilator runner not found" in line:
        return SkipRecord(
            name="rtl-sim-verilator-coverage",
            severity="HIGH",
            reason=line.strip(),
            would_catch="RTL simulation regressions that host-only tests and static checks cannot see",
            source="log",
        )
    return SkipRecord("soft-skip", "ADVISORY", line.strip(), "a skipped optional or environment-dependent check", "log")


def summarize(records: list[SkipRecord]) -> str:
    dedup: dict[tuple[str, str, str], SkipRecord] = {}
    for rec in records:
        dedup.setdefault((rec.name, rec.severity, rec.source), rec)
    ordered = sorted(dedup.values(), key=lambda r: (SEVERITY_ORDER.get(r.severity, 99), r.name, r.source))
    counts = {sev: sum(1 for r in ordered if r.severity == sev) for sev in SEVERITY_ORDER}
    lines = [
        "GATE_SKIP_SUMMARY_BEGIN",
        (
            "GATE_SKIP_SUMMARY total={total} critical={CRITICAL} high={HIGH} advisory={ADVISORY}"
        ).format(total=len(ordered), **counts),
    ]
    for rec in ordered:
        lines.append(
            f"GATE_SKIP {rec.severity} {rec.name}: reason={rec.reason}; "
            f"would_catch={rec.would_catch}; source={rec.source}"
        )
    if not ordered:
        lines.append("GATE_SKIP_NONE all registered critical/soft-skip checks covered or not emitted")
    lines.append("GATE_SKIP_SUMMARY_END")
    return "\n".join(lines)


def run_wrapped(label: str, cmd: list[str]) -> int:
    if not cmd:
        raise SystemExit("missing command after --")
    log_dir = ROOT / "build" / "gate_logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    log_path = log_dir / f"{safe_label}.log"
    records = registry_skips(label)
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        proc = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            log.write(line)
            rec = classify_skip_line(line)
            if rec:
                records.append(rec)
        rc = proc.wait()
        summary = summarize(records) + "\n"
        sys.stdout.write(summary)
        log.write(summary)
    return rc


def self_test() -> int:
    red = summarize(
        [
            classify_skip_line(
                "SKIP-NOT-PASS test_pms_baseline_profile: set PLEX_BASE, PLEX_TOKEN, "
                "and MISTERPLEX_BASELINE_KEY for the live PMS Baseline check."
            )
        ]  # type: ignore[list-item]
    )
    if "total=1 critical=1" not in red or "live-pms-baseline-profile" not in red:
        print(red)
        return 1
    green = summarize([])
    if "total=0 critical=0 high=0 advisory=0" not in green or "GATE_SKIP_NONE" not in green:
        print(green)
        return 1
    print("SELFTEST_RED_SUMMARY")
    print(red)
    print("SELFTEST_GREEN_SUMMARY")
    print(green)
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--label", default="gate")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv[1:])
    if args.self_test:
        return self_test()
    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    return run_wrapped(args.label, cmd)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
