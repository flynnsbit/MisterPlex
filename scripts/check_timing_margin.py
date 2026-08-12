#!/usr/bin/env python3
"""Fail post-fit STA reports that silently eat timing margin vs a baseline.

Unlike check_quartus_timing.py (negative slack only), this gate tracks named
clocks against a reference (default: wtime4) and fails when setup/hold margin
regresses beyond a configured threshold — even while slack remains positive.

Exit codes:
  0  PASS — all tracked margins within budget; TNS rules satisfied
  1  FAIL — margin regression, negative slack/TNS, or missing tracked clock
  2  usage / bad baseline config
  77 SKIP-NOT-PASS — STA absent, unreadable, or missing Setup/Hold summaries
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SKIP_RC = 77


@dataclass(frozen=True)
class SlackRow:
    section: str
    clock: str
    slack: float
    tns: float


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip(";").split(";")]


def number(text: str) -> float:
    m = re.search(r"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", text)
    if not m:
        raise ValueError(f"no number in {text!r}")
    return float(m.group(0))


def parse_slack_rows(path: Path) -> list[SlackRow]:
    """Parse Quartus STA Setup/Hold/... Summary tables (same shape as check_quartus_timing)."""
    rows: list[SlackRow] = []
    section = ""
    saw_header = False
    section_rows = 0
    try:
        text = path.read_text(errors="ignore")
    except OSError as exc:
        raise RuntimeError(f"unreadable STA report: {exc}") from exc

    for line in text.splitlines():
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
                try:
                    rows.append(
                        SlackRow(section, parts[0], number(parts[1]), number(parts[2]))
                    )
                except ValueError:
                    # Malformed numeric cell — treat whole report as unparseable later
                    continue
                section_rows += 1
            continue
    return rows


def load_baseline(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"TIMING_MARGIN_REFUSED(exit=2): bad baseline {path}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    if not isinstance(data, dict) or "clocks" not in data:
        print(f"TIMING_MARGIN_REFUSED(exit=2): baseline missing clocks: {path}", file=sys.stderr)
        raise SystemExit(2)
    return data


def find_row(rows: list[SlackRow], section: str, match: str) -> SlackRow | None:
    for row in rows:
        if row.section == section and row.clock == match:
            return row
    # Allow suffix/substring match if Quartus renames slightly
    for row in rows:
        if row.section == section and (match in row.clock or row.clock in match):
            return row
    return None


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sta-rpt", type=Path, required=True, help="Quartus Plex.sta.rpt path")
    ap.add_argument(
        "--baseline",
        type=Path,
        default=root / "assets" / "timing_margin_baseline.json",
        help="JSON baseline (default: assets/timing_margin_baseline.json)",
    )
    ap.add_argument(
        "--max-setup-regression-ns",
        type=float,
        default=None,
        help="Override baseline max_setup_regression_ns",
    )
    ap.add_argument(
        "--max-hold-regression-ns",
        type=float,
        default=None,
        help="Override baseline max_hold_regression_ns",
    )
    args = ap.parse_args(argv[1:])

    if not args.sta_rpt.exists():
        print(
            f"SKIP-NOT-PASS timing_margin: STA report absent: {args.sta_rpt}",
            file=sys.stderr,
        )
        return SKIP_RC
    if not args.baseline.exists():
        print(
            f"SKIP-NOT-PASS timing_margin: baseline absent: {args.baseline}",
            file=sys.stderr,
        )
        return SKIP_RC

    baseline = load_baseline(args.baseline)
    max_setup_reg = (
        args.max_setup_regression_ns
        if args.max_setup_regression_ns is not None
        else float(baseline.get("max_setup_regression_ns", 0.05))
    )
    max_hold_reg = (
        args.max_hold_regression_ns
        if args.max_hold_regression_ns is not None
        else float(baseline.get("max_hold_regression_ns", 0.05))
    )
    require_tns_zero = bool(baseline.get("require_tns_zero", True))

    try:
        rows = parse_slack_rows(args.sta_rpt)
    except RuntimeError as exc:
        print(f"SKIP-NOT-PASS timing_margin: {exc}", file=sys.stderr)
        return SKIP_RC

    setup_rows = [r for r in rows if r.section == "Setup"]
    hold_rows = [r for r in rows if r.section == "Hold"]
    if not setup_rows or not hold_rows:
        print(
            "SKIP-NOT-PASS timing_margin: STA missing Setup/Hold Summary tables "
            f"(setup_rows={len(setup_rows)} hold_rows={len(hold_rows)})",
            file=sys.stderr,
        )
        return SKIP_RC

    print("TIMING_MARGIN_BASELINE", baseline.get("name", args.baseline.name))
    print(
        f"TIMING_MARGIN_THRESHOLDS max_setup_regression_ns={max_setup_reg:g} "
        f"max_hold_regression_ns={max_hold_reg:g} require_tns_zero={require_tns_zero}"
    )
    print("TIMING_MARGIN_TABLE_BEGIN")
    print(
        "| clock | role | section | ref_ns | actual_ns | delta_ns | floor_ns | tns | status |"
    )
    print("|---|---|---|---:|---:|---:|---:|---:|---|")

    failures: list[str] = []
    clocks = baseline["clocks"]
    if not isinstance(clocks, dict) or not clocks:
        print("TIMING_MARGIN_REFUSED(exit=2): baseline clocks empty", file=sys.stderr)
        return 2

    for role, spec in clocks.items():
        if not isinstance(spec, dict):
            failures.append(f"{role}: invalid baseline spec")
            continue
        match = spec.get("match")
        if not match:
            failures.append(f"{role}: baseline missing match")
            continue

        require_present = bool(spec.get("require_present", False))

        for section, ref_key, max_reg, min_key in (
            ("Setup", "setup_ns", max_setup_reg, "min_setup_ns"),
            ("Hold", "hold_ns", max_hold_reg, "min_hold_ns"),
        ):
            ref = spec.get(ref_key)
            min_abs = spec.get(min_key)
            # Presence-only (no regression ref): still demand the clock when require_present
            if ref is None and min_abs is None and not (require_present and section == "Setup"):
                continue

            row = find_row(rows, section, match)
            if row is None:
                if ref is None and min_abs is None and require_present and section == "Setup":
                    msg = f"{role}/{section}: require_present clock missing from STA: {match}"
                else:
                    msg = f"{role}/{section}: tracked clock not in STA: {match}"
                failures.append(msg)
                ref_disp = "—" if ref is None else f"{float(ref):g}"
                print(
                    f"| `{match}` | {role} | {section} | {ref_disp} | — | — | — | — | MISSING |"
                )
                continue

            actual = row.slack
            status = "ok"
            if actual < 0 or row.tns < 0:
                status = "NEG_SLACK"
                failures.append(
                    f"{role}/{section}: negative slack/TNS actual={actual:g} tns={row.tns:g}"
                )
            elif require_tns_zero and row.tns != 0:
                status = "TNS_NONZERO"
                failures.append(f"{role}/{section}: TNS={row.tns:g} want 0")
            elif min_abs is not None and actual + 1e-12 < float(min_abs):
                status = "BELOW_MIN"
                failures.append(
                    f"{role}/{section}: actual={actual:g} < min={float(min_abs):g}"
                )

            if ref is not None:
                ref_f = float(ref)
                delta = actual - ref_f  # negative => erosion
                floor = ref_f - max_reg
                if status == "ok" and actual + 1e-12 < floor:
                    status = "REGRESSED"
                    failures.append(
                        f"{role}/{section}: actual={actual:g} < floor={floor:g} "
                        f"(ref={ref_f:g} max_regression={max_reg:g} delta={delta:g})"
                    )
                print(
                    f"| `{row.clock}` | {role} | {section} | {ref_f:g} | {actual:g} | "
                    f"{delta:g} | {floor:g} | {row.tns:g} | {status} |"
                )
            else:
                # Presence / absolute-min only (clk_pix first fit: no regression baseline yet)
                min_disp = "—" if min_abs is None else f"{float(min_abs):g}"
                print(
                    f"| `{row.clock}` | {role} | {section} | present | {actual:g} | "
                    f"— | {min_disp} | {row.tns:g} | {status} |"
                )

    print("TIMING_MARGIN_TABLE_END")

    # Always quote raw worst setup/hold across the whole STA (evidence, not gate inputs only)
    if setup_rows:
        worst_s = min(setup_rows, key=lambda r: r.slack)
        print(
            f"TIMING_MARGIN_RAW worst_setup clock=`{worst_s.clock}` "
            f"slack={worst_s.slack:g} tns={worst_s.tns:g}"
        )
    if hold_rows:
        worst_h = min(hold_rows, key=lambda r: r.slack)
        print(
            f"TIMING_MARGIN_RAW worst_hold clock=`{worst_h.clock}` "
            f"slack={worst_h.slack:g} tns={worst_h.tns:g}"
        )

    if failures:
        print("TIMING_MARGIN_REJECTED(exit=1):", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1

    print(f"PASS timing_margin: tracked clocks within budget ({baseline.get('name', args.baseline.name)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
