#!/usr/bin/env python3
"""Detect timing closure achieved by exclusion rather than by design.

Guards against the single most dangerous timing anti-pattern: adding
set_clock_groups -asynchronous or set_false_path to silence violations without
fixing the underlying timing issue. When paths disappear from the STA report,
the violation disappears too — but the silicon bug remains.

Three independent checks:
1. SDC EXCLUSION AUDIT — every set_clock_groups, set_false_path, set_max_delay,
   and set_multicycle_path in the constraint tree is inventoried and compared
   against a committed baseline. New exclusions fail unless accompanied by an
   entry in the baseline (with a mandatory justification string).
2. STA COVERAGE — the timing report must contain slack rows for a minimum set of
   expected clock domains. If a domain that was previously analysed disappears,
   that is evidence of exclusion and fails the gate.
3. EFFECTIVE EVIDENCE — when requested, bind actual SDC execution and resolved
   endpoint/clock-group inventories to the frozen sources and timing sidecar.

Exit codes:
  0 = PASS
  1 = REJECTED (new exclusion or missing STA coverage)
  4 = REFUSED (missing input file)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from quartus_sta_report import SLACK_SECTIONS, parse_sta_report

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = ROOT / "tests" / "fixtures" / "timing_exclusion_baseline.json"


@dataclass(frozen=True)
class Exclusion:
    file: str
    line_no: int
    kind: str          # clock_groups, false_path, max_delay, multicycle_path
    text: str          # full directive text (may span multiple lines)
    fingerprint: str   # hash for stable comparison


@dataclass
class StaCoverage:
    clocks: set[str] = field(default_factory=set)
    sections: set[str] = field(default_factory=set)
    total_rows: int = 0
    model_clocks: dict[str, set[str]] = field(default_factory=dict)
    model_rows: dict[str, int] = field(default_factory=dict)


def fingerprint(text: str) -> str:
    normalised = re.sub(r"\s+", " ", text.strip())
    return hashlib.sha256(normalised.encode()).hexdigest()[:16]


def parse_sdc_exclusions(path: Path) -> list[Exclusion]:
    """Extract timing exclusion directives from an SDC file."""
    if not path.exists():
        return []
    lines = path.read_text(errors="ignore").splitlines()
    exclusions: list[Exclusion] = []

    directive_re = re.compile(
        r"^\s*(set_clock_groups|set_false_path|set_max_delay|set_min_delay|set_multicycle_path)\b"
    )
    i = 0
    while i < len(lines):
        m = directive_re.match(lines[i])
        if not m:
            i += 1
            continue
        kind_raw = m.group(1)
        kind_map = {
            "set_clock_groups": "clock_groups",
            "set_false_path": "false_path",
            "set_max_delay": "max_delay",
            "set_min_delay": "min_delay",
            "set_multicycle_path": "multicycle_path",
        }
        kind = kind_map.get(kind_raw, kind_raw)
        # Collect continuation lines (ending with \)
        text_parts = [lines[i].rstrip()]
        while text_parts[-1].endswith("\\") and i + 1 < len(lines):
            i += 1
            text_parts.append(lines[i].rstrip())
        full_text = "\n".join(text_parts)
        start_line = i - len(text_parts) + 2  # 1-based
        exclusions.append(Exclusion(
            file=str(path),
            line_no=start_line,
            kind=kind,
            text=full_text.strip(),
            fingerprint=fingerprint(full_text),
        ))
        i += 1
    return exclusions


def discover_sdc_files(root: Path) -> list[Path]:
    """Find all SDC files in the FPGA project tree."""
    fpga_dir = root / "fpga"
    if not fpga_dir.exists():
        return []
    return sorted(fpga_dir.rglob("*.sdc"))


def load_baseline(path: Path) -> dict:
    if not path.exists():
        return {"exclusions": {}, "expected_sta_clocks": [], "min_sta_rows": 0}
    return json.loads(path.read_text())


def classify_exclusion(excl: Exclusion) -> str:
    """Flag high-risk exclusions that are likely timing evasion."""
    if excl.kind == "clock_groups":
        if "-asynchronous" in excl.text:
            return "HIGH_RISK: -asynchronous clock group (hides CDC violations)"
        if "-exclusive" in excl.text:
            return "mux-clock: legitimate if clocks are truly mux-selected"
    if excl.kind == "false_path":
        # I/O false paths are generally legitimate
        if "get_ports" in excl.text:
            return "io-false-path: standard for async I/O pins"
        # Config register false paths
        if any(sig in excl.text for sig in ["cfg[", "VSET[", "vol_att", "scaler_flt",
                                             "led_overtake", "led_state", "WIDTH[",
                                             "HEIGHT[", "FB_BASE", "FB_WIDTH", "FB_HEIGHT"]):
            return "config-register: quasi-static, acceptable if truly quasi-static"
        # OSD false paths
        if "_osd|" in excl.text:
            return "osd-false-path: OSD display timing, separate domain"
        # Scaler false paths
        if "ascal|" in excl.text:
            return "scaler-false-path: scaler configuration outputs"
        return "REVIEW: false_path on non-obvious target"
    if excl.kind == "multicycle_path":
        return "multicycle: acceptable with documented evidence"
    return "REVIEW: needs justification"


def parse_sta_clocks(path: Path) -> StaCoverage:
    """Extract clock names that appear in the STA slack summary."""
    cov = StaCoverage()
    if not path.exists():
        return cov
    report = parse_sta_report(path)
    for model, sections in report.sections.items():
        if sections & SLACK_SECTIONS:
            cov.model_clocks[model] = set()
            cov.model_rows[model] = 0
            cov.sections.update(sections & SLACK_SECTIONS)
    for row in report.slack_rows:
        cov.clocks.add(row.clock)
        cov.total_rows += 1
        cov.model_clocks[row.model].add(row.clock)
        cov.model_rows[row.model] += 1
    return cov


def format_exclusion_table(exclusions: list[Exclusion], baseline_fps: dict[str, str]) -> str:
    lines = [
        "| # | file | line | kind | fingerprint | baseline | risk |",
        "|---|---|---:|---|---|---|---|",
    ]
    for i, excl in enumerate(exclusions, 1):
        rel_file = excl.file.replace(str(ROOT) + "/", "")
        in_baseline = "yes" if excl.fingerprint in baseline_fps else "NEW"
        risk = classify_exclusion(excl)
        # Truncate text for display
        short_text = excl.text.replace("\n", " ")[:80]
        lines.append(
            f"| {i} | `{rel_file}` | {excl.line_no} | {excl.kind} | `{excl.fingerprint}` | {in_baseline} | {risk} |"
        )
    return "\n".join(lines)


def effective_exclusions(directory: Path, project: Path, sdcs: list[Path]) -> tuple[list[str], int, int]:
    from check_quartus_timing import parse_detailed_rows, read_evidence

    parse_detailed_rows(directory)
    manifest = json.loads(read_evidence(directory / "manifest.json", 8 * 1024**2))
    if manifest["schema"] != "misterplex.timing-paths.v2":
        raise ValueError("effective exception evidence requires the extended timing sidecar")
    evidence = manifest["extended"]
    inputs = json.loads(read_evidence(directory.parent / "inputs.json", 4 * 1024**2))
    root = project.resolve()
    provided = {path.resolve() for path in sdcs}
    expected = set()
    for relative in evidence["active_sdc_files"]:
        path = root / relative
        if path.is_symlink() or not path.resolve().is_relative_to(root) or path.resolve() not in provided:
            raise ValueError(f"active SDC is outside the supplied frozen sources: {relative}")
        data = read_evidence(path, 1024**2)
        if hashlib.sha256(data).hexdigest() != inputs["input_files"][relative]:
            raise ValueError(f"active SDC input hash mismatch: {relative}")
        expected.update((relative, item.line_no, "set_" + item.kind)
                        for item in parse_sdc_exclusions(path))
    actual = {(item["file"], item["line"], item["kind"]) for item in evidence["exceptions"]}
    if len(actual) != len(evidence["exceptions"]):
        raise ValueError("repeated exception execution at one source location needs explicit accounting")
    if actual != expected:
        raise ValueError(f"SDC execution coverage mismatch: missing={sorted(expected - actual)}, "
                         f"unexpected={sorted(actual - expected)}")
    errors = []
    empty_arguments = 0
    for item in evidence["exceptions"]:
        if item["kind"] == "set_clock_groups":
            groups = [argument for argument in item["arguments"] if argument["option"] == "-group"]
            if len(groups) < 2 or any(group["count"] == 0 for group in groups):
                errors.append(f"{item['file']}:{item['line']}: empty/incomplete resolved clock groups")
        for argument in item["arguments"]:
            if argument["mode"] == "implicit_all_keepers":
                continue
            if argument["count"] == 0:
                empty_arguments += 1
            if argument["explicit_decoder_objects"]:
                errors.append(f"{item['file']}:{item['line']}: {item['kind']} "
                              f"{argument['option']} explicitly excludes decoder keepers")
    return errors, len(actual), empty_arguments


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sdc", type=Path, action="append", default=[],
                    help="SDC file(s) to audit (default: discover all in fpga/)")
    ap.add_argument("--sta-rpt", type=Path,
                    help="STA report for coverage check")
    ap.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    ap.add_argument("--update-baseline", action="store_true",
                    help="write current exclusions as the new baseline (for initial setup)")
    ap.add_argument("--effective-dir", type=Path,
                    help="Require source-bound actual exception/endpoint inventories from timing/")
    ap.add_argument("--project", type=Path, help="Frozen compiler project for effective SDC source binding")
    args = ap.parse_args(argv[1:])
    if bool(args.effective_dir) != bool(args.project) or (args.effective_dir and args.update_baseline):
        print("TIMING_EXCLUSION_REFUSED(exit=4): effective evidence requires --project "
              "and cannot update the source baseline", file=sys.stderr)
        return 4

    sdc_files = args.sdc or discover_sdc_files(ROOT)
    if not sdc_files:
        print("TIMING_EXCLUSION_REFUSED(exit=4): no SDC files found", file=sys.stderr)
        return 4

    # Collect all exclusions
    all_exclusions: list[Exclusion] = []
    for sdc in sdc_files:
        if not sdc.exists():
            print(f"TIMING_EXCLUSION_REFUSED(exit=4): SDC file not found: {sdc}", file=sys.stderr)
            return 4
        all_exclusions.extend(parse_sdc_exclusions(sdc))

    baseline = load_baseline(args.baseline)
    baseline_fps: dict[str, str] = baseline.get("exclusions", {})
    expected_clocks: list[str] = baseline.get("expected_sta_clocks", [])
    min_sta_rows: int = baseline.get("min_sta_rows", 0)

    if args.update_baseline:
        new_baseline = {
            "schema": "misterplex.timing_exclusion_baseline.v1",
            "exclusions": {},
            "expected_sta_clocks": sorted(expected_clocks) if expected_clocks else [],
            "min_sta_rows": min_sta_rows,
        }
        for excl in all_exclusions:
            risk = classify_exclusion(excl)
            rel_file = excl.file.replace(str(ROOT) + "/", "")
            new_baseline["exclusions"][excl.fingerprint] = (
                f"{excl.kind} @ {rel_file}:{excl.line_no} — {risk}"
            )
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        args.baseline.write_text(json.dumps(new_baseline, indent=2) + "\n")
        print(f"Baseline updated: {len(all_exclusions)} exclusions written to {args.baseline}")
        return 0

    # --- Check 1: SDC exclusion audit ---
    print("TIMING_EXCLUSION_TABLE_BEGIN")
    print(format_exclusion_table(all_exclusions, baseline_fps))
    print("TIMING_EXCLUSION_TABLE_END")

    errors: list[str] = []
    new_exclusions = [e for e in all_exclusions if e.fingerprint not in baseline_fps]
    if new_exclusions:
        errors.append(f"{len(new_exclusions)} new SDC exclusion(s) not in baseline:")
        for excl in new_exclusions:
            rel_file = excl.file.replace(str(ROOT) + "/", "")
            risk = classify_exclusion(excl)
            errors.append(f"  {excl.kind} @ {rel_file}:{excl.line_no} fp={excl.fingerprint} — {risk}")
        errors.append(
            "  To accept: add fingerprint(s) to the baseline with justification, "
            "or run with --update-baseline to regenerate."
        )

    removed_fps = set(baseline_fps.keys()) - {e.fingerprint for e in all_exclusions}
    if removed_fps:
        # Removed exclusions aren't errors — they mean constraints were tightened.
        # But they're noteworthy.
        for fp in sorted(removed_fps):
            print(f"NOTE: baseline exclusion {fp} no longer present: {baseline_fps[fp]}")

    # High-risk flag: any -asynchronous clock group
    for excl in all_exclusions:
        if excl.kind == "clock_groups" and "-asynchronous" in excl.text:
            if excl.fingerprint not in baseline_fps:
                errors.append(
                    f"HIGH RISK: set_clock_groups -asynchronous @ "
                    f"{excl.file}:{excl.line_no} — this hides CDC timing violations. "
                    f"If this is intentional, add fp={excl.fingerprint} to baseline with "
                    f"hardware evidence."
                )

    # --- Check 2: STA coverage ---
    if args.sta_rpt:
        if not args.sta_rpt.exists():
            print(f"TIMING_EXCLUSION_REFUSED(exit=4): STA report not found: {args.sta_rpt}", file=sys.stderr)
            return 4
        try:
            cov = parse_sta_clocks(args.sta_rpt)
        except (OSError, ValueError) as exc:
            print(f"TIMING_EXCLUSION_REFUSED(exit=4): {exc}", file=sys.stderr)
            return 4
        print(f"STA coverage: {cov.total_rows} slack rows, "
              f"{len(cov.clocks)} clocks ({', '.join(sorted(cov.clocks))}), "
              f"sections: {', '.join(sorted(cov.sections))}")

        if min_sta_rows > 0 and cov.total_rows < min_sta_rows:
            errors.append(
                f"STA row count {cov.total_rows} < baseline minimum {min_sta_rows}: "
                f"paths may have been excluded from analysis"
            )
        for expected_clk in expected_clocks:
            if expected_clk not in cov.clocks:
                errors.append(
                    f"expected clock '{expected_clk}' missing from STA report: "
                    f"it may have been excluded by a new set_clock_groups or set_false_path"
                )
        for model, clocks in cov.model_clocks.items():
            if not model:
                continue
            print(f"STA model coverage: {model}: {cov.model_rows[model]} slack rows, {len(clocks)} clocks")
            if min_sta_rows > 0 and cov.model_rows[model] < min_sta_rows:
                errors.append(f"STA model '{model}' row count {cov.model_rows[model]} < baseline minimum {min_sta_rows}")
            for expected_clk in expected_clocks:
                if expected_clk not in clocks:
                    errors.append(f"expected clock '{expected_clk}' missing from STA model '{model}'")

        # Empty STA (zero analysed rows) is always an error
        if cov.total_rows == 0:
            errors.append(
                "STA report contains ZERO analysed slack rows — "
                "timing cannot be 'met' if nothing was checked"
            )
    elif expected_clocks or min_sta_rows > 0:
        print(
            "NOTE: baseline requires STA coverage check but --sta-rpt was not provided; "
            "SDC exclusion audit only. Provide --sta-rpt for full gate.",
            file=sys.stderr,
        )

    if args.effective_dir:
        try:
            effective_errors, active_count, empty_count = effective_exclusions(
                args.effective_dir, args.project, sdc_files)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(f"TIMING_EXCLUSION_REFUSED(exit=4): {exc}", file=sys.stderr)
            return 4
        errors.extend(effective_errors)
        print(f"Effective SDC coverage: {active_count} executed source exclusions; "
              f"{len(all_exclusions) - active_count} unsourced exclusions; "
              f"{empty_count} explicit empty collections retained with ignored-SDC reports")
        print("Clock-group evidence: resolved membership; not a Spectra-Q path-report claim")

    if errors:
        print("TIMING_EXCLUSION_REJECTED(exit=1):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1

    coverage = ("source-bound execution/resolved-object and ignored-SDC evidence retained"
                if args.effective_dir else
                "blind_spot=only_checks_SDC_text_not_Quartus_internal_optimisations")
    print(f"PASS timing exclusion audit: {len(all_exclusions)} SDC exclusion(s) all in baseline; "
          f"no new exclusions; {coverage}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
