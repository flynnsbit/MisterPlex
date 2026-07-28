#!/usr/bin/env python3
"""Verilator lint baseline gate for MiSTerPlex-owned RTL."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

from check_define_parity import verilator_define_args

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "fpga" / "Plex_MiSTer"
DEFAULT_BASELINE = ROOT / "tests" / "fixtures" / "rtl_lint_baseline.json"
WARN_RE = re.compile(r"^%Warning-([A-Z0-9_]+):\s+([^:]+):(\d+):(\d+):")
ERROR_FILE_RE = re.compile(r"^%Error(?:-[A-Z0-9_]+)?:\s+([^:]+):(\d+):(\d+):")
INTERESTING_RE = re.compile(r"^(?:WIDTHTRUNC|WIDTHEXPAND|WIDTH|UNSIGNED|IMPLICIT)")
ASSIGN_RE = re.compile(r"set_global_assignment\b.*?-name\s+(SYSTEMVERILOG_FILE|VERILOG_FILE|QIP_FILE)\b\s+(.+)$")
MACRO_RE = re.compile(r"set_global_assignment\b.*?-name\s+VERILOG_MACRO\b\s+(.+)$")
SOURCE_RE = re.compile(r"^\s*source\s+(.+?)\s*$")


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def strip_comment(line: str) -> str:
    return line.split("#", 1)[0].strip()


def resolve_quartus_path(raw: str, base_dir: Path) -> list[Path]:
    raw = raw.strip().rstrip(";").strip()
    if not raw:
        return []
    if raw.startswith("[file join"):
        parts = re.findall(r'"([^"]+)"|([^\s\[\]]+)', raw)
        tokens = [a or b for a, b in parts]
        out: list[str] = []
        for tok in tokens:
            if tok in {"file", "join"} or tok.startswith("$::quartus"):
                continue
            out.append(tok)
        if out:
            return [base_dir.joinpath(*out).resolve()]
    if "pll_q" in raw and "regexp" in raw:
        return sorted(base_dir.glob("pll_q*.qip"))
    raw = raw.strip('"')
    if raw.startswith("["):
        return []
    p = Path(raw)
    if not p.is_absolute():
        by_base = (base_dir / p).resolve()
        p = by_base if by_base.exists() else (PROJECT / p).resolve()
    return [p]


def clean_assignment_value(raw: str) -> str:
    return raw.strip().rstrip(";").strip().strip('"').strip()


def parse_assignment_file(path: Path, seen: set[Path], ordered: list[Path], macros: list[str]) -> None:
    path = path.resolve()
    if path in seen or not path.exists():
        return
    seen.add(path)
    base_dir = path.parent
    for raw_line in path.read_text(errors="ignore").splitlines():
        line = strip_comment(raw_line)
        if not line:
            continue
        sm = SOURCE_RE.match(line)
        if sm:
            for source in resolve_quartus_path(sm.group(1), base_dir):
                parse_assignment_file(source, seen, ordered, macros)
            continue
        mm = MACRO_RE.search(line)
        if mm:
            macro = clean_assignment_value(mm.group(1))
            if macro and macro not in macros:
                macros.append(macro)
            continue
        am = ASSIGN_RE.search(line)
        if not am:
            continue
        kind, value = am.groups()
        for source in resolve_quartus_path(value, base_dir):
            if kind == "QIP_FILE":
                parse_assignment_file(source, seen, ordered, macros)
            elif source.suffix.lower() in {".sv", ".v", ".vh"} and source.exists():
                if source not in ordered:
                    ordered.append(source)


def discover_design() -> tuple[list[Path], list[str]]:
    ordered: list[Path] = []
    macros: list[str] = []
    seen: set[Path] = set()
    parse_assignment_file(PROJECT / "Plex.qsf", seen, ordered, macros)
    parse_assignment_file(PROJECT / "files.qip", seen, ordered, macros)
    return ordered, macros


def discover_sources() -> list[Path]:
    return discover_design()[0]


def is_excluded(path: Path) -> bool:
    try:
        r = rel(path)
    except ValueError:
        return True
    return (
        "/sys/" in f"/{r}"
        or "/rtl/pll/" in f"/{r}"
        or r in {"fpga/Plex_MiSTer/rtl/pll.v", "fpga/Plex_MiSTer/build_id.v"}
    )


def write_intel_stubs() -> Path:
    stub = ROOT / "build" / "rtl_lint_intel_stubs.sv"
    stub.parent.mkdir(exist_ok=True)
    stub.write_text(r'''
module altsyncram #(
    parameter numwords_a = 0, parameter widthad_a = 0, parameter width_a = 0,
    parameter numwords_b = 0, parameter widthad_b = 0, parameter width_b = 0,
    parameter address_reg_b = "", parameter clock_enable_input_a = "",
    parameter clock_enable_input_b = "", parameter clock_enable_output_a = "",
    parameter clock_enable_output_b = "", parameter indata_reg_b = "",
    parameter intended_device_family = "", parameter lpm_type = "",
    parameter operation_mode = "", parameter outdata_aclr_a = "",
    parameter outdata_aclr_b = "", parameter outdata_reg_a = "",
    parameter outdata_reg_b = "", parameter power_up_uninitialized = "",
    parameter read_during_write_mode_port_a = "", parameter read_during_write_mode_port_b = "",
    parameter width_byteena_a = 0, parameter width_byteena_b = 0,
    parameter wrcontrol_wraddress_reg_b = ""
) (
    input clock0, input clock1, input [255:0] address_a, input [255:0] data_a, input wren_a,
    output [255:0] q_a, input [255:0] address_b, input [255:0] data_b, input wren_b, output [255:0] q_b,
    input aclr0, input aclr1, input addressstall_a, input addressstall_b, input [255:0] byteena_a,
    input [255:0] byteena_b, input clocken0, input clocken1, input clocken2, input clocken3,
    output [2:0] eccstatus, input rden_a, input rden_b
);
endmodule
module stratixv_lcell_comb #(parameter lut_mask = 64'h0, parameter dont_touch = "off") (input dataa, input datab, input datac, input datad, input datae, input dataf, output combout); endmodule
module arriav_lcell_comb #(parameter lut_mask = 64'h0, parameter dont_touch = "off") (input dataa, input datab, input datac, input datad, input datae, input dataf, output combout); endmodule
module arriavgz_lcell_comb #(parameter lut_mask = 64'h0, parameter dont_touch = "off") (input dataa, input datab, input datac, input datad, input datae, input dataf, output combout); endmodule
module cyclonev_lcell_comb #(parameter lut_mask = 64'h0, parameter dont_touch = "off") (input dataa, input datab, input datac, input datad, input datae, input dataf, output combout); endmodule
module altera_std_synchronizer #(parameter depth = 2) (input clk, input reset_n, input din, output dout); endmodule
module altera_pll #(
    parameter fractional_vco_multiplier = "", parameter reference_clock_frequency = "",
    parameter operation_mode = "", parameter number_of_clocks = 1,
    parameter output_clock_frequency0 = "", parameter phase_shift0 = "", parameter duty_cycle0 = 50,
    parameter output_clock_frequency1 = "", parameter phase_shift1 = "", parameter duty_cycle1 = 50,
    parameter output_clock_frequency2 = "", parameter phase_shift2 = "", parameter duty_cycle2 = 50,
    parameter output_clock_frequency3 = "", parameter phase_shift3 = "", parameter duty_cycle3 = 50,
    parameter output_clock_frequency4 = "", parameter phase_shift4 = "", parameter duty_cycle4 = 50,
    parameter output_clock_frequency5 = "", parameter phase_shift5 = "", parameter duty_cycle5 = 50,
    parameter output_clock_frequency6 = "", parameter phase_shift6 = "", parameter duty_cycle6 = 50,
    parameter output_clock_frequency7 = "", parameter phase_shift7 = "", parameter duty_cycle7 = 50,
    parameter output_clock_frequency8 = "", parameter phase_shift8 = "", parameter duty_cycle8 = 50,
    parameter output_clock_frequency9 = "", parameter phase_shift9 = "", parameter duty_cycle9 = 50,
    parameter output_clock_frequency10 = "", parameter phase_shift10 = "", parameter duty_cycle10 = 50,
    parameter output_clock_frequency11 = "", parameter phase_shift11 = "", parameter duty_cycle11 = 50,
    parameter output_clock_frequency12 = "", parameter phase_shift12 = "", parameter duty_cycle12 = 50,
    parameter output_clock_frequency13 = "", parameter phase_shift13 = "", parameter duty_cycle13 = 50,
    parameter output_clock_frequency14 = "", parameter phase_shift14 = "", parameter duty_cycle14 = 50,
    parameter output_clock_frequency15 = "", parameter phase_shift15 = "", parameter duty_cycle15 = 50,
    parameter output_clock_frequency16 = "", parameter phase_shift16 = "", parameter duty_cycle16 = 50,
    parameter output_clock_frequency17 = "", parameter phase_shift17 = "", parameter duty_cycle17 = 50,
    parameter pll_type = "", parameter pll_subtype = ""
) (input refclk, input rst, input fbclk, output [17:0] outclk, output locked, output fboutclk); endmodule
module altddio_out #(parameter extend_oe_disable = "", parameter intended_device_family = "", parameter invert_output = "", parameter lpm_hint = "", parameter lpm_type = "", parameter oe_reg = "", parameter power_up_high = "", parameter width = 1) (input datain_h, input datain_l, input outclock, output dataout, input aclr, input aset, input oe, input outclocken, input sclr, input sset); endmodule
''')
    # build_id.v is generated by Quartus at compile time (build_id.tcl).
    # Provide a lint stub so Verilator can actually parse Plex.sv —
    # without this, the include fails and Plex.sv is NEVER LINTED.
    build_id_stub = ROOT / "build" / "build_id.v"
    build_id_stub.write_text('`define BUILD_DATE "lint_stub"\n')
    return stub


def run_verilator(files: list[Path], macros: list[str]) -> tuple[int, str]:
    stub = write_intel_stubs()
    ordered_files = sorted(files, key=lambda p: (is_excluded(p), rel(p) if p.exists() else str(p)))
    cmd = [
        str(ROOT / "scripts" / "run_verilator.sh"),
        "--lint-only", "-Wall", "-Wno-fatal",
        "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-PINMISSING",
        "-Wno-MULTITOP", "-Wno-EOFNEWLINE", "-Wno-GENUNNAMED",
        f"-I{PROJECT}", f"-I{PROJECT / 'sys'}", f"-I{PROJECT / 'rtl'}",
        f"-I{ROOT / 'build'}",
        str(stub),
    ] + verilator_define_args() + [str(p) for p in ordered_files]
    proc = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout


def collect_warnings(output: str, reportable: set[str]) -> tuple[dict[str, dict[str, int]], dict[str, list[str]]]:
    counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    details: dict[str, list[str]] = defaultdict(list)
    for line in output.splitlines():
        m = WARN_RE.match(line)
        if not m:
            continue
        kind, file_name, line_no, _col = m.groups()
        if not INTERESTING_RE.match(kind):
            continue
        p = Path(file_name)
        if not p.is_absolute():
            p = (ROOT / p).resolve()
        try:
            r = rel(p)
        except ValueError:
            continue
        if r in reportable:
            counts[r][kind] += 1
            msg = line.split(": ", 1)[1] if ": " in line else line
            details[r].append(f"{kind}:{line_no}: {msg}")
    return ({f: dict(kinds) for f, kinds in sorted(counts.items())},
            {f: sorted(items) for f, items in sorted(details.items())})


def reportable_errors(output: str, reportable: set[str]) -> tuple[list[str], list[str]]:
    owned: list[str] = []
    ignored: list[str] = []
    for line in output.splitlines():
        if not line.startswith("%Error"):
            continue
        if line.startswith("%Error: Exiting due"):
            continue
        m = ERROR_FILE_RE.match(line)
        if not m:
            owned.append(line)
            continue
        p = Path(m.group(1))
        if not p.is_absolute():
            p = (ROOT / p).resolve()
        try:
            r = rel(p)
        except ValueError:
            ignored.append(line)
            continue
        (owned if r in reportable else ignored).append(line)
    return owned, ignored


def load_baseline(path: Path) -> tuple[dict[str, dict[str, int]], dict[str, list[str]]]:
    data = json.loads(path.read_text())
    counts = {str(f): {str(k): int(v) for k, v in kinds.items()} for f, kinds in data.get("warnings", {}).items()}
    details = {str(f): [str(item) for item in items] for f, items in data.get("warning_details", {}).items()}
    return counts, details


def write_baseline(path: Path, warnings: dict[str, dict[str, int]], details: dict[str, list[str]], files: set[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "schema": "misterplex.rtl_lint_baseline.v1",
        "project": "fpga/Plex_MiSTer/Plex.qsf",
        "warning_classes": ["WIDTHTRUNC", "WIDTHEXPAND", "WIDTH", "UNSIGNED", "IMPLICIT*"],
        "excluded_prefixes": ["fpga/Plex_MiSTer/sys/", "fpga/Plex_MiSTer/rtl/pll/"],
        "files": sorted(files),
        "warnings": warnings,
        "warning_details": details,
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def total(kinds: dict[str, int]) -> int:
    return sum(kinds.values())


def print_ranked(warnings: dict[str, dict[str, int]]) -> None:
    print("RTL lint warning counts (owned RTL only; vendor/generated excluded):")
    if not warnings:
        print("  clean: 0 tracked warnings")
        return
    for file_name, kinds in sorted(warnings.items(), key=lambda kv: (-total(kv[1]), kv[0])):
        detail = " ".join(f"{k}={v}" for k, v in sorted(kinds.items()))
        print(f"  {total(kinds):3d}  {file_name}  {detail}")


def compare_to_baseline(current: dict[str, dict[str, int]], baseline: dict[str, dict[str, int]],
                        current_details: dict[str, list[str]], baseline_details: dict[str, list[str]]) -> list[str]:
    regressions: list[str] = []
    for file_name in sorted(set(current) | set(baseline)):
        for kind in sorted(set(current.get(file_name, {})) | set(baseline.get(file_name, {}))):
            cur = current.get(file_name, {}).get(kind, 0)
            base = baseline.get(file_name, {}).get(kind, 0)
            if cur > base:
                regressions.append(f"{file_name}: {kind} {cur} > baseline {base}")
                old = set(baseline_details.get(file_name, []))
                new = [item for item in current_details.get(file_name, []) if item.startswith(kind + ':') and item not in old]
                for item in new[:8]:
                    regressions.append(f"  new {file_name}: {item}")
    return regressions


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__ + "\nThis is a Verilator parse/lint gate, not a Quartus synthesis-validity gate.")
    ap.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--list-files", action="store_true")
    args = ap.parse_args()

    files, macros = discover_design()
    reportable = {rel(p) for p in files if not is_excluded(p)}
    if args.list_files:
        for f in sorted(reportable):
            print(f)
        return 0

    probe = subprocess.run([str(ROOT / "scripts" / "run_verilator.sh"), "--version"], cwd=ROOT,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if probe.returncode == 127:
        print("RTL LINT REFUSED(exit=3): Verilator not found; whole-design RTL lint was NOT run.", file=sys.stderr)
        print("Install oss-cad-suite under ~/.local/oss-cad-suite or set VERILATOR=/path/to/verilator.", file=sys.stderr)
        return 3
    if probe.returncode != 0:
        print("RTL LINT ERROR: Verilator probe failed:", file=sys.stderr)
        print(probe.stdout, file=sys.stderr)
        return probe.returncode

    plex_rel = "fpga/Plex_MiSTer/Plex.sv"
    module_files = [p for p in files if rel(p) in reportable and rel(p) != plex_rel]
    rc, output = run_verilator(module_files, macros)

    # Plex.sv depends on MiSTer sys/generated modules. Run a separate context pass
    # and count only warnings physically reported against Plex.sv; vendor/generated
    # diagnostics from the context are excluded from the gate.
    plex_files = [p for p in files if rel(p) == plex_rel]
    top_output = ""
    top_rc = 0
    if plex_files:
        all_context = sorted({p for p in PROJECT.rglob("*") if p.suffix.lower() in {".sv", ".v"} and p not in plex_files})
        top_rc, top_output = run_verilator(plex_files + all_context, macros)

    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build" / "rtl_lint_verilator.log").write_text(
        "=== owned module pass ===\n" + output + "\n=== Plex.sv context pass ===\n" + top_output
    )
    current, current_details = collect_warnings(output, reportable)
    top_counts, top_details = collect_warnings(top_output, {plex_rel})
    for file_name, kinds in top_counts.items():
        current.setdefault(file_name, {})
        for kind, value in kinds.items():
            current[file_name][kind] = current[file_name].get(kind, 0) + value
    for file_name, items in top_details.items():
        current_details.setdefault(file_name, [])
        current_details[file_name].extend(item for item in items if item not in current_details[file_name])
        current_details[file_name].sort()

    print(f"RTL lint: using {probe.stdout.strip()}")
    print(f"RTL lint: parsed {len(files)} Quartus RTL/context files; reporting {len(reportable)} owned files")
    if macros:
        print("RTL lint: propagated QSF macros " + " ".join(macros))
    print_ranked(current)

    owned_errors, ignored_errors = reportable_errors(output, reportable - {plex_rel})
    top_owned_errors, top_ignored_errors = reportable_errors(top_output, {plex_rel})
    # Vendor/framework context errors from the top-level pass (sys/, pll/, etc.)
    # are expected — Verilator cannot elaborate Intel megafunctions.
    ignored_errors += top_ignored_errors

    # Plex.sv errors: only ignore individually-allowlisted ones.
    # With the build_id.v lint stub, no Plex.sv errors should be allowlisted.
    # Keep the mechanism for future use if genuinely unavoidable errors arise.
    PLEX_ERROR_ALLOWLIST: list[str] = [
        # Empty: build_id.v is now resolved by build/build_id.v stub.
        # Any new entry here requires a written justification.
    ]
    plex_allowed = []
    plex_real_errors = []
    for err in top_owned_errors:
        if any(allow_text in err for allow_text in PLEX_ERROR_ALLOWLIST):
            plex_allowed.append(err)
        else:
            plex_real_errors.append(err)
    ignored_errors += plex_allowed
    owned_errors += plex_real_errors

    if ignored_errors:
        print(f"RTL lint: ignored {len(ignored_errors)} vendor/context errors "
              f"({len(plex_allowed)} allowlisted Plex.sv); "
              f"see build/rtl_lint_verilator.log")
    if owned_errors:
        print("RTL LINT ERROR: Verilator reported errors in owned RTL (see build/rtl_lint_verilator.log):", file=sys.stderr)
        for line in owned_errors[:20]:
            print(f"  {line}", file=sys.stderr)
        return rc or top_rc or 1

    if args.write_baseline:
        write_baseline(args.baseline, current, current_details, reportable)
        print(f"RTL lint: wrote baseline {args.baseline}")
        return 0

    if not args.baseline.exists():
        print(f"RTL LINT ERROR: missing baseline {args.baseline}; run --write-baseline intentionally", file=sys.stderr)
        return 2
    baseline_counts, baseline_details = load_baseline(args.baseline)
    regressions = compare_to_baseline(current, baseline_counts, current_details, baseline_details)
    if regressions:
        print("RTL LINT REGRESSION above checked-in baseline:", file=sys.stderr)
        for item in regressions:
            print(f"  {item}", file=sys.stderr)
        return 1
    print(f"RTL lint: PASS no warning regressions above {args.baseline}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
