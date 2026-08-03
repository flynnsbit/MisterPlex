#!/usr/bin/env python3
"""One-pass Quartus STA interrogation — Fmax, slack, named critical-path owner.

Parent burned by miss #18 (Fmax owned by decode_stub placeholder). This script
always names the owner when a path dump is available.

Inputs
------
  --sta-rpt PATH/Plex.sta.rpt          required (Fmax + Setup/Hold summaries)
  --path-dump FILE                     optional TimeQuest path table (From/To)
  --path-dump FILE [FILE ...]          repeatable; all merged, worst slack first
  --path-dir DIR                       glob *setup*.txt / *timing*.txt inside

Default product clocks (Cyclone V MiSTer Plex):
  clk_sys = emu|pll|...|general[0]...divclk   ship 20.000 MHz
  clk_ddr = emu|pll|...|general[2]...divclk   ship 90.000 MHz

Corner of record: Slow 1100mV 100C (string checked in report).

Prints in one shot:
  - CORNER_HINT
  - Fmax table (clk_sys / clk_ddr highlighted)
  - Setup/Hold slack table; worst clk_sys setup slack
  - CRITICAL_PATH_OWNER From→To + module name + banned-placeholder check
  - TOP10_PATHS (lowest slack first) with owner module each
  - VERDICT (optional gate)

Exit:
  0 PASS (gate mode defaults)
  1 HARD FAIL (neg slack / Fmax floor / banned owner / unknown owner)
  2 bad args
  4 missing file
  5 unparseable

Gate floors default ON (ship PLL). Use --report-only to always exit 0 after print
(still prints FAIL lines for visibility).

Examples
--------
  # Full one-pass after fit (recommended):
  scripts/sta_onepass_interrogation.py \\
    --sta-rpt out/Plex.sta.rpt \\
    --path-dump out/clk_sys_sameclk_setup.txt

  # Generate path dumps first:
  quartus_sta -t scripts/l4_sta_dump_paths.tcl Plex Plex out/
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


BANNED = ("decode_stub", ":stub|", "|stub|", "placeholder")


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
    launch: str
    latch: str
    source: str


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip(";").split(";")]


def number(text: str) -> float | None:
    m = re.search(r"-?\d+(?:\.\d+)?", text.replace(",", ""))
    return float(m.group(0)) if m else None


def clock_kind(name: str) -> str:
    n = name.lower()
    if "audio" in n:
        return "clk_audio"
    if "hdmi" in n:
        return "clk_hdmi"
    if "emu|pll|" in n or "emu/pll/" in n:
        if "general[0]" in n:
            return "clk_sys"
        if "general[2]" in n:
            return "clk_ddr"
    return "other"


def module_of(node: str) -> str:
    """Extract a human module owner from a Quartus hierarchical node name."""
    # Prefer deepest named instance: type:inst|
    parts = [p for p in node.split("|") if p]
    # Walk from leaf back for a recognizable RTL module
    interesting = (
        "slice_hdr_parser",
        "decode_stub",
        "present_content_window",
        "present_beam_content_de",
        "present_core",
        "ddr_frame_store",
        "ddr_bitstream_reader",
        "stream_path",
        "h264_",
        "ascal",
        "sysmem",
        "residual_csum",
    )
    for p in reversed(parts):
        low = p.lower()
        for key in interesting:
            if key in low:
                # type:inst or plain
                if ":" in p:
                    return p.split(":")[0] if key in p.split(":")[0].lower() else p
                return p.split("[")[0]
    # Fallback: last type:inst
    for p in reversed(parts):
        if ":" in p:
            return p.split(":")[0]
    return parts[-1] if parts else node


def owner_banned(frm: str, to: str) -> bool:
    blob = f"{frm}|{to}"
    return any(b in blob for b in BANNED)


def parse_fmax(path: Path) -> list[tuple[str, float, float]]:
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
        if in_fmax and saw_header and not line.strip() and rows:
            break
        if in_fmax and saw_header and line.startswith(";"):
            parts = cells(line)
            if len(parts) >= 3 and parts[0] and parts[0] != "Fmax":
                f = number(parts[0])
                r = number(parts[1]) if len(parts) > 1 else f
                clk = parts[2]
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
    rows: list[PathRow] = []
    src = str(path)
    for line in path.read_text(errors="ignore").splitlines():
        if not line.startswith(";"):
            continue
        if "From Node" in line or "Summary of Paths" in line:
            continue
        parts = cells(line)
        # Summary table: Slack | From | To | Launch | Latch | Rel | Skew | DataDelay
        if len(parts) < 4:
            continue
        slack = number(parts[0])
        if slack is None:
            continue
        frm, to = parts[1], parts[2]
        if not frm or not to:
            continue
        if "|" not in frm and "emu" not in frm and "ascal" not in frm:
            continue
        launch = parts[3] if len(parts) > 3 else ""
        latch = parts[4] if len(parts) > 4 else ""
        data_delay = number(parts[7]) if len(parts) > 7 else number(parts[-1])
        rows.append(
            PathRow(slack, frm, to, data_delay, launch, latch, src)
        )
    rows.sort(key=lambda r: r.slack)
    return rows


def collect_path_dumps(dumps: list[Path], path_dir: Path | None) -> list[Path]:
    out: list[Path] = list(dumps)
    if path_dir is not None:
        if not path_dir.is_dir():
            return out
        for pat in ("*setup*.txt", "*timing*.txt", "*path*.txt"):
            out.extend(sorted(path_dir.glob(pat)))
    # unique preserve order
    seen: set[str] = set()
    uniq: list[Path] = []
    for p in out:
        k = str(p.resolve()) if p.exists() else str(p)
        if k not in seen:
            seen.add(k)
            uniq.append(p)
    return uniq


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--sta-rpt", type=Path, required=True)
    ap.add_argument("--path-dump", type=Path, action="append", default=[], dest="path_dumps")
    ap.add_argument("--path-dir", type=Path, default=None)
    ap.add_argument("--clk-sys-min-mhz", type=float, default=20.0)
    ap.add_argument("--clk-ddr-min-mhz", type=float, default=90.0)
    ap.add_argument("--top", type=int, default=10, help="top-N worst paths to print")
    ap.add_argument(
        "--report-only",
        action="store_true",
        help="print everything; always exit 0 (no gate)",
    )
    ap.add_argument(
        "--allow-unknown-owner",
        action="store_true",
        help="do not fail when no path dump / no From-To",
    )
    args = ap.parse_args(argv[1:])

    print("STA_ONEPASS_BEGIN")
    print(f"sta_rpt={args.sta_rpt}")

    if not args.sta_rpt.exists():
        print(f"STA_REFUSED(exit=4): missing {args.sta_rpt}", file=sys.stderr)
        return 4

    dump_files = collect_path_dumps(args.path_dumps, args.path_dir)
    # Auto-sibling: if path dumps sit next to sta.rpt
    if not dump_files:
        sib = args.sta_rpt.parent
        dump_files = collect_path_dumps([], sib)
        dump_files = [p for p in dump_files if p.suffix == ".txt"]

    print(f"path_dumps={[str(p) for p in dump_files] if dump_files else 'NONE'}")

    text = args.sta_rpt.read_text(errors="ignore")
    corner = "UNKNOWN"
    if "Slow 1100mV 100C" in text:
        corner = "Slow 1100mV 100C"
    elif "slow 1100mv 100c" in text.lower():
        corner = "Slow 1100mV 100C (case-folded match)"
    print(f"CORNER_HINT={corner}")

    fmax_rows = parse_fmax(args.sta_rpt)
    slack_rows = parse_slack_tables(args.sta_rpt)
    if not fmax_rows:
        print("STA_UNPARSEABLE(exit=5): no Fmax Summary", file=sys.stderr)
        return 5
    if not slack_rows:
        print("STA_UNPARSEABLE(exit=5): no slack Summary", file=sys.stderr)
        return 5

    print("FMAX_TABLE_BEGIN")
    print("| kind | Fmax_MHz | Restricted_MHz | clock |")
    print("|---|---:|---:|---|")
    sys_fmax = ddr_fmax = None
    for clk, f, r in fmax_rows:
        kind = clock_kind(clk)
        print(f"| {kind} | {f:g} | {r:g} | `{clk}` |")
        if kind == "clk_sys" and sys_fmax is None:
            sys_fmax = f
        if kind == "clk_ddr" and ddr_fmax is None:
            ddr_fmax = f
    print("FMAX_TABLE_END")
    print(f"CLK_SYS_FMAX_MHZ={sys_fmax if sys_fmax is not None else 'MISSING'}")
    print(f"CLK_DDR_FMAX_MHZ={ddr_fmax if ddr_fmax is not None else 'MISSING'}")

    print("SLACK_TABLE_BEGIN")
    print("| section | kind | slack | TNS | clock |")
    print("|---|---|---:|---:|---|")
    worst_sys_setup = None
    worst_any_setup = None
    for row in slack_rows:
        kind = clock_kind(row.clock)
        print(
            f"| {row.section} | {kind} | {row.slack:g} | {row.tns:g} | `{row.clock}` |"
        )
        if row.section == "Setup":
            if worst_any_setup is None or row.slack < worst_any_setup[0]:
                worst_any_setup = (row.slack, kind, row.clock)
            if kind == "clk_sys":
                if worst_sys_setup is None or row.slack < worst_sys_setup:
                    worst_sys_setup = row.slack
    print("SLACK_TABLE_END")
    print(
        f"WORST_CLK_SYS_SETUP_SLACK_NS="
        f"{worst_sys_setup if worst_sys_setup is not None else 'MISSING'}"
    )
    if worst_any_setup:
        print(
            f"WORST_SETUP_ANY={worst_any_setup[0]:g} kind={worst_any_setup[1]} "
            f"clock=`{worst_any_setup[2]}`"
        )

    # Paths
    paths: list[PathRow] = []
    for dp in dump_files:
        if not dp.exists():
            print(f"WARN missing path dump {dp}", file=sys.stderr)
            continue
        paths.extend(parse_path_dump(dp))
    paths.sort(key=lambda r: r.slack)

    # Prefer sameclk clk_sys paths for "Fmax owner"; else overall worst
    sameclk_sys = [
        p
        for p in paths
        if clock_kind(p.launch) == "clk_sys" and clock_kind(p.latch) == "clk_sys"
    ]
    owner_pool = sameclk_sys if sameclk_sys else paths

    print(f"PATH_ROWS_TOTAL={len(paths)} SAMECLK_SYS={len(sameclk_sys)}")

    crit = owner_pool[0] if owner_pool else None
    if crit is None:
        print("CRITICAL_PATH_OWNER=UNKNOWN")
        print("CRITICAL_PATH_MODULE=UNKNOWN")
        print("CRITICAL_PATH_BANNED=UNKNOWN")
    else:
        mod_from = module_of(crit.frm)
        mod_to = module_of(crit.to)
        banned = owner_banned(crit.frm, crit.to)
        print(f"CRITICAL_PATH_SLACK_NS={crit.slack:g}")
        if crit.data_delay is not None:
            print(f"CRITICAL_PATH_DATA_DELAY_NS={crit.data_delay:g}")
        print(f"CRITICAL_PATH_FROM=`{crit.frm}`")
        print(f"CRITICAL_PATH_TO=`{crit.to}`")
        print(f"CRITICAL_PATH_MODULE_FROM={mod_from}")
        print(f"CRITICAL_PATH_MODULE_TO={mod_to}")
        print(f"CRITICAL_PATH_OWNER_MODULES={mod_from}->{mod_to}")
        print(f"CRITICAL_PATH_BANNED={'YES' if banned else 'NO'}")
        print(f"CRITICAL_PATH_LAUNCH_KIND={clock_kind(crit.launch)}")
        print(f"CRITICAL_PATH_LATCH_KIND={clock_kind(crit.latch)}")
        print(f"CRITICAL_PATH_SOURCE={crit.source}")

    print(f"TOP{args.top}_PATHS_BEGIN")
    print("| rank | slack | fail? | owner_modules | from | to | launch_kind | latch_kind |")
    print("|---:|---:|---|---|---|---|---|---|")
    top = paths[: args.top]
    for i, p in enumerate(top, 1):
        mf, mt = module_of(p.frm), module_of(p.to)
        fail = "YES" if p.slack < 0 else "no"
        print(
            f"| {i} | {p.slack:g} | {fail} | {mf}->{mt} | `{p.frm}` | `{p.to}` | "
            f"{clock_kind(p.launch)} | {clock_kind(p.latch)} |"
        )
    if not top:
        print("| — | — | — | NO_PATH_DUMP | — | — | — | — |")
    print(f"TOP{args.top}_PATHS_END")

    # Markers in sta text (instance names often absent from summary-only export)
    for marker in (
        "decode_stub",
        "residual_csum",
        "slice_hdr_parser",
        "present_content_window",
        "y_line",
        "ddr_frame_store",
    ):
        print(f"STA_TEXT_HAS_{marker}={'YES' if marker in text else 'NO'}")

    fails: list[str] = []
    neg = [r for r in slack_rows if r.slack < 0 or r.tns < 0]
    if neg:
        fails.append(f"negative_slack count={len(neg)}")
        for r in neg[:8]:
            fails.append(
                f"  {r.section} {clock_kind(r.clock)} slack={r.slack:g} tns={r.tns:g}"
            )
    if sys_fmax is None:
        fails.append("clk_sys Fmax missing")
    elif sys_fmax < args.clk_sys_min_mhz:
        fails.append(f"clk_sys Fmax {sys_fmax:g} < {args.clk_sys_min_mhz:g}")
    if ddr_fmax is None:
        fails.append("clk_ddr Fmax missing")
    elif ddr_fmax < args.clk_ddr_min_mhz:
        fails.append(f"clk_ddr Fmax {ddr_fmax:g} < {args.clk_ddr_min_mhz:g}")
    if crit is None:
        if not args.allow_unknown_owner:
            fails.append(
                "critical path owner UNKNOWN — provide --path-dump "
                "(scripts/l4_sta_dump_paths.tcl) or --allow-unknown-owner"
            )
    elif owner_banned(crit.frm, crit.to):
        fails.append(
            f"BANNED owner (placeholder) {module_of(crit.frm)}->{module_of(crit.to)} "
            f"— miss #18 class"
        )
    if corner == "UNKNOWN":
        fails.append("corner Slow 1100mV 100C not found in sta.rpt text")

    print("VERDICT_CHECKS_BEGIN")
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
    else:
        print("FAIL: none")
    print("VERDICT_CHECKS_END")

    if args.report_only:
        print("STA_ONEPASS_VERDICT=REPORT_ONLY")
        print("STA_ONEPASS_END")
        return 0

    if fails:
        print("STA_ONEPASS_VERDICT=FAIL", file=sys.stderr)
        print("STA_ONEPASS_END")
        return 1

    print("STA_ONEPASS_VERDICT=PASS")
    print(
        f"SUMMARY clk_sys_fmax={sys_fmax} sys_setup_slack={worst_sys_setup} "
        f"owner={module_of(crit.frm) if crit else '?'}->{module_of(crit.to) if crit else '?'}"
    )
    print("STA_ONEPASS_END")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
