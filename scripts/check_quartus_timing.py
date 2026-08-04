#!/usr/bin/env python3
"""Fail Quartus STA reports with negative timing slack or hollow parse.

Empty/unparsed STA must NOT PASS (rd-duck: prior gate greened zero rows).
Optional --require-clock / --min-fmax-mhz enforce clk_pix (general[3]) presence
on PRESENT_CLK_PIX_PLL fits.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SlackRow:
    section: str
    clock: str
    slack: float
    tns: float


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip(";").split(";")]


def number(text: str) -> float:
    m = re.search(r"-?\d+(?:\.\d+)?", text)
    return float(m.group(0)) if m else 0.0


def parse_slack_rows(path: Path) -> list[SlackRow]:
    rows: list[SlackRow] = []
    section = ""
    saw_header = False
    section_rows = 0
    for line in path.read_text(errors="ignore").splitlines():
        m = re.match(r"; (Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\s+;", line)
        if m:
            section = m.group(1)
            saw_header = False
            section_rows = 0
            continue
        if section and "Clock" in line and "Slack" in line:
            saw_header = True
            continue
        if section and saw_header and line.startswith("+---") and section_rows > 0:
            section = ""
            saw_header = False
            section_rows = 0
            continue
        if section and saw_header and line.startswith(";"):
            parts = cells(line)
            if len(parts) >= 3 and parts[0] and not parts[0].startswith("+") and parts[0] != "Clock":
                rows.append(SlackRow(section, parts[0], number(parts[1]), number(parts[2])))
                section_rows += 1
            continue
    return rows


def parse_fmax_rows(path: Path) -> list[tuple[str, str, str]]:
    """Return list of (clock_name, fmax_str, restricted_str)."""
    rows: list[tuple[str, str, str]] = []
    in_fmax = False
    saw_header = False
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("; Fmax Summary"):
            in_fmax = True
            saw_header = False
            continue
        if in_fmax and "Fmax" in line and "Clock Name" in line:
            saw_header = True
            continue
        if in_fmax and saw_header and line.startswith("+---") and rows:
            break
        if in_fmax and saw_header and line.startswith(";"):
            parts = cells(line)
            if len(parts) >= 3 and parts[0] and not parts[0].startswith("+") and "Fmax" not in parts[0]:
                # columns: Fmax ; Restricted ; Clock Name
                rows.append((parts[2], parts[0], parts[1]))
            continue
        if in_fmax and saw_header and not line.strip():
            break
    return rows


def parse_mhz(text: str) -> float | None:
    m = re.search(r"(\d+(?:\.\d+)?)\s*MHz", text, re.I)
    return float(m.group(1)) if m else None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sta-rpt", type=Path, required=True)
    ap.add_argument(
        "--require-clock",
        action="append",
        default=[],
        metavar="SUBSTR",
        help="require this substring in at least one Setup Summary clock (repeatable)",
    )
    ap.add_argument(
        "--min-setup-rows",
        type=int,
        default=1,
        help="minimum Setup Summary rows (default 1; empty parse is FAIL not PASS)",
    )
    ap.add_argument(
        "--min-fmax-mhz",
        action="append",
        default=[],
        metavar="SUBSTR:MHZ",
        help="require Fmax Summary clock matching SUBSTR with Fmax >= MHZ (repeatable)",
    )
    args = ap.parse_args(argv[1:])
    if not args.sta_rpt.exists():
        print(f"QUARTUS_TIMING_REFUSED(exit=4): missing STA report {args.sta_rpt}", file=sys.stderr)
        return 4

    fmax = parse_fmax_rows(args.sta_rpt)
    slack_rows = parse_slack_rows(args.sta_rpt)
    setup_rows = [r for r in slack_rows if r.section == "Setup"]

    print("TIMING_FMAX_TABLE_BEGIN")
    print("| clock | Fmax | Restricted Fmax |")
    print("|---|---:|---:|")
    for clock, fmax_value, restricted in fmax:
        print(f"| `{clock}` | {fmax_value} | {restricted} |")
    print("TIMING_FMAX_TABLE_END")
    print("TIMING_SLACK_TABLE_BEGIN")
    print("| section | clock | slack | endpoint TNS |")
    print("|---|---|---:|---:|")
    for row in slack_rows:
        print(f"| {row.section} | `{row.clock}` | {row.slack:g} | {row.tns:g} |")
    print("TIMING_SLACK_TABLE_END")

    errors: list[str] = []

    if len(setup_rows) < args.min_setup_rows:
        errors.append(
            f"Setup Summary rows={len(setup_rows)} < min_setup_rows={args.min_setup_rows}: "
            "empty/unparsed STA must not PASS (hollow gate)"
        )

    setup_clocks = [r.clock for r in setup_rows]
    for substr in args.require_clock:
        if not any(substr in c for c in setup_clocks):
            errors.append(
                f"required Setup clock substring {substr!r} missing from STA "
                f"(have {len(setup_clocks)} setup clock(s))"
            )

    for spec in args.min_fmax_mhz:
        if ":" not in spec:
            errors.append(f"bad --min-fmax-mhz {spec!r}, want SUBSTR:MHZ")
            continue
        substr, mhz_s = spec.rsplit(":", 1)
        try:
            need = float(mhz_s)
        except ValueError:
            errors.append(f"bad --min-fmax-mhz MHz in {spec!r}")
            continue
        matched = [(c, f, r) for c, f, r in fmax if substr in c]
        if not matched:
            errors.append(f"required Fmax clock substring {substr!r} missing from Fmax Summary")
            continue
        best = None
        for c, f, _r in matched:
            mhz = parse_mhz(f)
            if mhz is not None and (best is None or mhz > best[0]):
                best = (mhz, c, f)
        if best is None:
            errors.append(f"Fmax clock {substr!r}: could not parse MHz from {matched!r}")
        elif best[0] + 1e-9 < need:
            errors.append(
                f"Fmax clock `{best[1]}` = {best[0]:g} MHz < required {need:g} MHz"
            )

    failures = [row for row in slack_rows if row.slack < 0 or row.tns < 0]
    for row in failures:
        errors.append(
            f"negative slack/TNS {row.section}: {row.clock}: "
            f"slack={row.slack:g} endpoint_tns={row.tns:g}"
        )

    if errors:
        print("QUARTUS_TIMING_REJECTED(exit=1):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    print(
        "PASS timing: no negative setup/hold/recovery/removal/min-pulse slack"
        + (f"; required_clocks={args.require_clock}" if args.require_clock else "")
        + (f"; min_fmax={args.min_fmax_mhz}" if args.min_fmax_mhz else "")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
