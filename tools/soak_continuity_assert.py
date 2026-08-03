#!/usr/bin/env python3
"""Prove a soak window was uninterrupted by daemon respawn.

WHY
---
Per-stream counters (drops/presents/vfps/pfps) reset on every new play and are
zeroed again when misterplexd dies and the supervisor respawns. A "flat drops
over N minutes" claim is only valid if process identity was constant for the
whole window.

Identity (source):
  process_epoch  — stamped once per daemon life (steady mono_ms at boot)
  pid            — OS pid; changes on every respawn (added on 1 Hz media line)
  session_epoch  — process_epoch.stream_seq (also changes on new stream)

This tool NEVER SSHes. Parent pulls logs/ledger off-device and runs it here.

Exit codes (capture DIRECTLY: cmd; echo "true rc=$?"):
  0   CONTINUITY_OK
  2   CONTINUITY_FAIL (respawn / multi-epoch / multi-pid in window)
  77  NO-DATA (no process_epoch samples — cannot claim continuity)
  1   usage

Rule 0: values tagged measured | NO-DATA. Absence of SUPERVISE_EXIT in a log
slice is absence-of-evidence, not proof of no exit — prefer process_epoch.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import List, Optional, Set, Tuple

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_NO_DATA = 77

RE_PROCESS_EPOCH = re.compile(r"\bprocess_epoch=([0-9]+)\b")
RE_PID = re.compile(r"\bpid=([0-9]+)\b")
RE_SESSION_EPOCH = re.compile(r"\bsession_epoch=([0-9]+\.[0-9]+)\b")
RE_DROPS = re.compile(r"\bdrops=([0-9]+)\b")
RE_PROCESS_START = re.compile(r"event=process_start\b")
RE_PROCESS_EXIT = re.compile(r"event=process_exit\b")
RE_SUPERVISE_EXIT = re.compile(r"SUPERVISE_EXIT\b|EXIT pid=\d+ rc=")


def _load_lines(paths: List[Path]) -> List[str]:
    out: List[str] = []
    for p in paths:
        if not p.is_file():
            continue
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        out.extend(text.splitlines())
    return out


def analyze(
    log_lines: List[str], ledger_lines: List[str]
) -> Tuple[int, str, dict]:
    epochs: List[str] = []
    pids: List[str] = []
    session_epochs: List[str] = []
    drops_vals: List[int] = []
    for line in log_lines:
        m = RE_PROCESS_EPOCH.search(line)
        if m:
            epochs.append(m.group(1))
        # pid= on media / ledger / EXIT_REASON — never si_pid= (sender of kill).
        if ("media:" in line or "event=process_" in line or "EXIT_REASON" in line) and (
            " pid=" in line or line.startswith("pid=") or "\tpid=" in line
        ):
            cleaned = re.sub(r"\bsi_pid=[0-9]+", " ", line)
            mp = re.search(r"(?:^|[\s])pid=([0-9]+)\b", cleaned)
            if mp:
                pids.append(mp.group(1))
        ms = RE_SESSION_EPOCH.search(line)
        if ms:
            session_epochs.append(ms.group(1))
        if "media:" in line and "drops=" in line:
            md = RE_DROPS.search(line)
            if md:
                drops_vals.append(int(md.group(1)))

    # ledger process boundaries
    n_start = sum(1 for ln in ledger_lines if RE_PROCESS_START.search(ln))
    n_exit = sum(1 for ln in ledger_lines if RE_PROCESS_EXIT.search(ln))
    n_sup = sum(1 for ln in log_lines if RE_SUPERVISE_EXIT.search(ln))

    uniq_e = sorted(set(epochs))
    uniq_p = sorted(set(pids))
    uniq_s = sorted(set(session_epochs))

    info = {
        "n_process_epoch_samples": len(epochs),
        "unique_process_epochs": uniq_e,
        "n_pid_samples": len(pids),
        "unique_pids": uniq_p,
        "unique_session_epochs": uniq_s,
        "ledger_process_starts": n_start,
        "ledger_process_exits": n_exit,
        "supervise_exit_lines": n_sup,
        "drops_first": drops_vals[0] if drops_vals else None,
        "drops_last": drops_vals[-1] if drops_vals else None,
        "drops_samples": len(drops_vals),
        "tag": "measured" if epochs else "NO-DATA",
    }

    if not epochs:
        return (
            RC_NO_DATA,
            "CONTINUITY_NO_DATA: no process_epoch= samples in inputs "
            "(live binary may predate process_epoch; cannot prove continuity)",
            info,
        )

    reasons = []
    if len(uniq_e) != 1:
        reasons.append(f"process_epoch changed: {uniq_e}")
    if pids and len(uniq_p) != 1:
        reasons.append(f"pid changed: {uniq_p}")
    # stream change alone is not a daemon respawn — report but do not fail
    stream_note = ""
    if len(uniq_s) > 1:
        stream_note = f" NOTE session_epoch multi={uniq_s} (new stream, not necessarily respawn)"

    if n_start > 1 or n_exit > 0:
        # ledger covering the soak window with an exit is a hard fail
        if n_exit > 0:
            reasons.append(f"ledger process_exit count={n_exit}")
        if n_start > 1:
            reasons.append(f"ledger process_start count={n_start} (>1)")

    if n_sup > 0:
        reasons.append(f"SUPERVISE_EXIT lines in log slice={n_sup}")

    if reasons:
        return (
            RC_FAIL,
            "CONTINUITY_FAIL: " + "; ".join(reasons) + stream_note,
            info,
        )

    return (
        RC_OK,
        "CONTINUITY_OK process_epoch="
        + uniq_e[0]
        + (f" pid={uniq_p[0]}" if uniq_p else " pid=NO-DATA")
        + f" samples={len(epochs)}"
        + stream_note,
        info,
    )


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--log",
        action="append",
        default=[],
        help="Daemon log / media telemetry capture (repeatable)",
    )
    ap.add_argument(
        "--ledger",
        action="append",
        default=[],
        help="misterplexd.frame_ledger path (repeatable)",
    )
    ap.add_argument(
        "--require-pid",
        action="store_true",
        help="FAIL/NO-DATA if pid= never appears (new media line contract)",
    )
    args = ap.parse_args(argv)

    log_paths = [Path(p) for p in args.log]
    led_paths = [Path(p) for p in args.ledger]
    if not log_paths and not led_paths:
        print("usage: soak_continuity_assert.py --log PATH [--ledger PATH]", file=sys.stderr)
        return RC_USAGE

    log_lines = _load_lines(log_paths)
    ledger_lines = _load_lines(led_paths)
    # Also scan logs for ledger-shaped rows
    for ln in log_lines:
        if "event=process_" in ln:
            ledger_lines.append(ln)

    rc, msg, info = analyze(log_lines, ledger_lines)
    if args.require_pid and info["n_pid_samples"] == 0 and rc == RC_OK:
        rc = RC_NO_DATA
        msg = "CONTINUITY_NO_DATA: --require-pid set but no pid= samples"

    print(msg)
    for k, v in info.items():
        print(f"  {k}={v} tag={info['tag']}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
