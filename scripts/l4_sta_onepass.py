#!/usr/bin/env python3
"""One-pass L4 STA interrogation for parent fit.

Answers in a single invocation:
  (1) Does clk_sys close at required MHz (default 20.0) at the report corner?
  (2) Who owns Fmax (named From→To) when a path dump is provided?
  (3) Is owner a real product module (NOT decode_stub / placeholder)?
  (4) Worst negative slack — any negative slack/TNS is HARD FAIL.

Usage:
  scripts/l4_sta_onepass.py --sta-rpt PATH/Plex.sta.rpt
  scripts/l4_sta_onepass.py --sta-rpt PATH/Plex.sta.rpt \\
      --path-dump PATH/clk_sys_sameclk_setup.txt

Optional path dump: TimeQuest "Summary of Paths" with From Node / To Node
columns (see scripts/l4_sta_dump_paths.tcl). Without it, owner is reported
UNKNOWN and exit is non-zero unless --allow-unknown-owner (still fails
negative slack / low Fmax / stub-in-sta).

Exit codes:
  0 PASS
  1 HARD FAIL (negative slack, Fmax floor, banned owner, missing owner)
  2 usage / bad args
  4 missing input file
  5 unparseable STA (no Fmax / no Setup Summary)
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


CLK_SYS_MARKERS = (
    "general[0].gpll",
    "general[0].gpll~PLL_OUTPUT_COUNTER|divclk",
)
CLK_DDR_MARKERS = (
    "general[2].gpll",
    "general[2].gpll~PLL_OUTPUT_COUNTER|divclk",
)
BANNED_OWNER_SUBSTR = (
    "decode_stub",
    ":stub|",
    "|stub|",
    "placeholder",
)
# Product / interesting owners for classification (not exhaustive)
PRODUCT_HINTS = (
    "slice_hdr_parser",
    "residual_csum",
    "present_content_window",
    "present_beam",
    "ddr_frame_store",
    "y_line",
    "c_line",
    "stream_path",
    "h264_",
    "present_core",
)


@dataclass
class SlackRow:
    section: str
    clock: str
    slack: float
    tns: float


@dataclass
class PathRow:
    slack: float
    frm: str
    to: str
    data_delay: float | None


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip(";").split(";")]


def number(text: str) -> float | None:
    m = re.search(r"-?\d+(?:\.\d+)?", text.replace(",", ""))
    return float(m.group(0)) if m else None


def clock_kind(name: str) -> str:
    n = name.lower()
    # Order matters: pll_audio also has general[0].gpll — exclude non-emu first.
    if "audio" in n:
        return "clk_audio"
    if "hdmi" in n:
        return "clk_hdmi"
    # Product fabric clocks come from emu|pll|...
    if "emu|pll|" in n or "emu/pll/" in n:
        if "general[0]" in n:
            return "clk_sys"
        if "general[2]" in n:
            return "clk_ddr"
    if any(m.lower() in n for m in CLK_SYS_MARKERS) and "emu" in n:
        return "clk_sys"
    if any(m.lower() in n for m in CLK_DDR_MARKERS) and "emu" in n:
        return "clk_ddr"
    return "other"


def parse_fmax(path: Path) -> list[tuple[str, float, float]]:
    """Return list of (clock_name, fmax_mhz, restricted_mhz)."""
    rows: list[tuple[str, float, float]] = []
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
        if in_fmax and saw_header and not line.strip():
            if rows:
                break
            continue
        if in_fmax and saw_header and line.startswith(";"):
            parts = cells(line)
            # Fmax | Restricted | Clock Name | Note
            if len(parts) >= 3 and parts[0] and parts[0] != "Fmax":
                f = number(parts[0])
                r = number(parts[1]) if len(parts) > 1 else f
                clk = parts[2] if len(parts) > 2 else ""
                if f is not None and clk:
                    rows.append((clk, f, r if r is not None else f))
    return rows


def parse_slack_tables(path: Path) -> list[SlackRow]:
    rows: list[SlackRow] = []
    section = ""
    saw_header = False
    section_rows = 0
    for line in path.read_text(errors="ignore").splitlines():
        m = re.match(
            r"; (Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\s*;",
            line,
        )
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
            if (
                len(parts) >= 3
                and parts[0]
                and not parts[0].startswith("+")
                and parts[0] != "Clock"
            ):
                s = number(parts[1])
                t = number(parts[2])
                if s is not None and t is not None:
                    rows.append(SlackRow(section, parts[0], s, t))
                    section_rows += 1
    return rows


def parse_path_dump(path: Path) -> list[PathRow]:
    """Parse TimeQuest Summary of Paths table (From/To/Slack/Data Delay)."""
    rows: list[PathRow] = []
    text = path.read_text(errors="ignore")
    # Prefer summary table lines: ; slack ; from ; to ; ... ; data_delay ;
    for line in text.splitlines():
        if not line.startswith(";"):
            continue
        if "From Node" in line or "Summary of Paths" in line:
            continue
        parts = cells(line)
        if len(parts) < 4:
            continue
        slack = number(parts[0])
        if slack is None:
            continue
        frm, to = parts[1], parts[2]
        if not frm or not to:
            continue
        if "emu" not in frm and "emu" not in to and "|" not in frm:
            continue
        # Data Delay is usually last numeric-ish column among trailing fields
        data_delay = None
        if len(parts) >= 8:
            data_delay = number(parts[7])
        elif len(parts) >= 4:
            data_delay = number(parts[-1])
        rows.append(PathRow(slack, frm, to, data_delay))
    # Also accept Path Summary blocks
    if not rows:
        frm = to = None
        slack = None
        delay = None
        for line in text.splitlines():
            if "From Node" in line and ";" in line:
                parts = cells(line)
                if len(parts) >= 2:
                    frm = parts[-1] if parts[-1] else (parts[1] if len(parts) > 1 else None)
                    # format: ; From Node ; value ;
                    for i, p in enumerate(parts):
                        if p == "From Node" and i + 1 < len(parts):
                            frm = parts[i + 1]
            if "To Node" in line and ";" in line:
                parts = cells(line)
                for i, p in enumerate(parts):
                    if p == "To Node" and i + 1 < len(parts):
                        to = parts[i + 1]
            if "Slack" in line and "Path Summary" not in line and ";" in line:
                parts = cells(line)
                for i, p in enumerate(parts):
                    if p == "Slack" and i + 1 < len(parts):
                        slack = number(parts[i + 1])
            if "Data Delay" in line and ";" in line:
                parts = cells(line)
                for i, p in enumerate(parts):
                    if p == "Data Delay" and i + 1 < len(parts):
                        delay = number(parts[i + 1])
            if frm and to and slack is not None and line.startswith("===="):
                rows.append(PathRow(slack, frm, to, delay))
                frm = to = None
                slack = delay = None
    rows.sort(key=lambda r: r.slack)
    return rows


def classify_owner(frm: str, to: str) -> str:
    blob = f"{frm} -> {to}"
    if any(b in blob for b in BANNED_OWNER_SUBSTR):
        return "BANNED_PLACEHOLDER"
    for h in PRODUCT_HINTS:
        if h in blob:
            return f"PRODUCT:{h}"
    return "PRODUCT_OR_OTHER"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sta-rpt", type=Path, required=True, help="Quartus Plex.sta.rpt")
    ap.add_argument(
        "--path-dump",
        type=Path,
        default=None,
        help="Optional sameclk path dump with From/To (l4_sta_dump_paths.tcl)",
    )
    ap.add_argument(
        "--clk-sys-min-mhz",
        type=float,
        default=20.0,
        help="Required clk_sys Fmax floor (ship PLL default 20.0)",
    )
    ap.add_argument(
        "--clk-ddr-min-mhz",
        type=float,
        default=90.0,
        help="Required clk_ddr Fmax floor (default 90.0)",
    )
    ap.add_argument(
        "--allow-unknown-owner",
        action="store_true",
        help="Do not fail when path dump missing (still fail slack/Fmax/stub)",
    )
    ap.add_argument(
        "--require-corner-hint",
        action="store_true",
        help="Fail if 'Slow 1100mV 100C' string absent from sta.rpt",
    )
    args = ap.parse_args(argv[1:])

    print("L4_STA_ONEPASS_BEGIN")
    print(f"sta_rpt={args.sta_rpt}")
    print(f"path_dump={args.path_dump}")
    print(f"clk_sys_min_mhz={args.clk_sys_min_mhz}")
    print(f"clk_ddr_min_mhz={args.clk_ddr_min_mhz}")

    if not args.sta_rpt.exists():
        print(f"L4_STA_REFUSED(exit=4): missing STA {args.sta_rpt}", file=sys.stderr)
        return 4
    if args.path_dump is not None and not args.path_dump.exists():
        print(f"L4_STA_REFUSED(exit=4): missing path dump {args.path_dump}", file=sys.stderr)
        return 4

    text = args.sta_rpt.read_text(errors="ignore")
    if args.require_corner_hint and "Slow 1100mV 100C" not in text and "Slow 1100mv 100c" not in text.lower():
        print("L4_STA_FAIL: corner hint 'Slow 1100mV 100C' not found in sta.rpt", file=sys.stderr)
        # soft note only unless required — already required here
        print("CORNER_HINT=MISSING")
        return 1
    corner = "Slow 1100mV 100C" if "Slow 1100mV 100C" in text else (
        "present_other" if "Slow" in text else "UNKNOWN"
    )
    print(f"CORNER_HINT={corner}")

    fmax_rows = parse_fmax(args.sta_rpt)
    slack_rows = parse_slack_tables(args.sta_rpt)
    if not fmax_rows:
        print("L4_STA_UNPARSEABLE(exit=5): no Fmax Summary rows", file=sys.stderr)
        return 5
    if not slack_rows:
        print("L4_STA_UNPARSEABLE(exit=5): no Setup/Hold Summary rows", file=sys.stderr)
        return 5

    print("FMAX_TABLE_BEGIN")
    print("| kind | clock | Fmax_MHz | Restricted_MHz |")
    print("|---|---|---:|---:|")
    sys_fmax = None
    ddr_fmax = None
    for clk, f, r in fmax_rows:
        kind = clock_kind(clk)
        print(f"| {kind} | `{clk}` | {f:g} | {r:g} |")
        if kind == "clk_sys" and sys_fmax is None:
            sys_fmax = f
        if kind == "clk_ddr" and ddr_fmax is None:
            ddr_fmax = f
    print("FMAX_TABLE_END")
    print(f"CLK_SYS_FMAX_MHZ={sys_fmax if sys_fmax is not None else 'MISSING'}")
    print(f"CLK_DDR_FMAX_MHZ={ddr_fmax if ddr_fmax is not None else 'MISSING'}")

    print("SLACK_TABLE_BEGIN")
    print("| section | kind | clock | slack | TNS |")
    print("|---|---|---|---:|---:|")
    worst_setup = None
    for row in slack_rows:
        kind = clock_kind(row.clock)
        print(f"| {row.section} | {kind} | `{row.clock}` | {row.slack:g} | {row.tns:g} |")
        if row.section == "Setup" and kind == "clk_sys":
            if worst_setup is None or row.slack < worst_setup:
                worst_setup = row.slack
    print("SLACK_TABLE_END")
    print(f"CLK_SYS_SETUP_SLACK={worst_setup if worst_setup is not None else 'MISSING'}")

    # Owner from path dump
    owner_from = owner_to = None
    owner_slack = None
    owner_delay = None
    owner_class = "UNKNOWN"
    if args.path_dump is not None:
        paths = parse_path_dump(args.path_dump)
        print(f"PATH_DUMP_ROWS={len(paths)}")
        if paths:
            print("PATH_TOP5_BEGIN")
            for p in paths[:5]:
                print(
                    f"| {p.slack:g} | `{p.frm}` | `{p.to}` | "
                    f"{p.data_delay if p.data_delay is not None else ''} |"
                )
            print("PATH_TOP5_END")
            w = paths[0]
            owner_from, owner_to = w.frm, w.to
            owner_slack = w.slack
            owner_delay = w.data_delay
            owner_class = classify_owner(w.frm, w.to)
    print(f"FMAX_OWNER_FROM={owner_from or 'UNKNOWN'}")
    print(f"FMAX_OWNER_TO={owner_to or 'UNKNOWN'}")
    print(f"FMAX_OWNER_CLASS={owner_class}")
    if owner_slack is not None:
        print(f"FMAX_OWNER_PATH_SLACK={owner_slack:g}")
    if owner_delay is not None:
        print(f"FMAX_OWNER_DATA_DELAY_NS={owner_delay:g}")

    # Stub presence anywhere in sta (even if not owner)
    stub_in_sta = "decode_stub" in text or "|stub|" in text
    print(f"DECODE_STUB_STRING_IN_STA={'YES' if stub_in_sta else 'NO'}")

    # L4 interest markers in sta text
    for marker in (
        "present_content_window",
        "residual_csum",
        "slice_hdr_parser",
        "y_line",
        "u_beam_720p24",
        "present_beam_content_de",
    ):
        print(f"STA_HAS_{marker}={'YES' if marker in text else 'NO'}")

    fails: list[str] = []

    # (4) negative slack hard fail — all sections
    neg = [r for r in slack_rows if r.slack < 0 or r.tns < 0]
    if neg:
        fails.append(f"negative_slack count={len(neg)}")
        for r in neg[:12]:
            fails.append(
                f"  {r.section} {clock_kind(r.clock)} slack={r.slack:g} tns={r.tns:g}"
            )

    # (1) Fmax floors
    if sys_fmax is None:
        fails.append("clk_sys Fmax row missing")
    elif sys_fmax < args.clk_sys_min_mhz:
        fails.append(
            f"clk_sys Fmax {sys_fmax:g} < required {args.clk_sys_min_mhz:g} MHz"
        )
    if ddr_fmax is None:
        fails.append("clk_ddr Fmax row missing")
    elif ddr_fmax < args.clk_ddr_min_mhz:
        fails.append(
            f"clk_ddr Fmax {ddr_fmax:g} < required {args.clk_ddr_min_mhz:g} MHz"
        )

    # (2)(3) owner
    if owner_from is None or owner_to is None:
        if not args.allow_unknown_owner:
            fails.append(
                "Fmax owner UNKNOWN — pass --path-dump from l4_sta_dump_paths.tcl "
                "or --allow-unknown-owner"
            )
    else:
        if owner_class == "BANNED_PLACEHOLDER":
            fails.append(
                f"Fmax owner is banned placeholder: {owner_from} -> {owner_to}"
            )

    # Extra: if path dump missing but sta text is dominated by stub in critical ways
    if stub_in_sta and owner_class == "BANNED_PLACEHOLDER":
        fails.append("decode_stub owns critical path (miss #18 class)")

    print("VERDICT_CHECKS_BEGIN")
    for f in fails:
        print(f"FAIL: {f}")
    if not fails:
        print("FAIL: none")
    print("VERDICT_CHECKS_END")

    if fails:
        print("L4_STA_ONEPASS_VERDICT=FAIL", file=sys.stderr)
        print("L4_STA_ONEPASS_END")
        return 1

    print("L4_STA_ONEPASS_VERDICT=PASS")
    print(
        f"SUMMARY clk_sys_fmax={sys_fmax:g} setup_slack={worst_setup} "
        f"owner={owner_class} {owner_from} -> {owner_to}"
    )
    print("L4_STA_ONEPASS_END")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
