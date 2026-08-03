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


def set_repo_root(root: Path) -> None:
    """Retarget file discovery to a scan/integration tree (fit-gate --root).

    Gate scripts may live in the canonical w-fitgate ruler while RTL/QSF come
    from a merged integration worktree. discover_design must read THAT tree's
    Plex.qsf + files.qip — not the ruler's.
    """
    global ROOT, PROJECT, DEFAULT_BASELINE
    ROOT = Path(root).resolve()
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


def discover_design(
    macro_qsf: Path | None = None,
    *,
    project_root: Path | None = None,
) -> tuple[list[Path], list[str]]:
    """Discover Quartus RTL file list + product macros.

    File list always comes from the project Plex.qsf + files.qip (what the fit
    compiles). Macros may be taken from an alternate QSF (fit-release gate) so
    elaboration can be forced to the *intended* fit macro set without editing
    the live project file mid-gate.

    project_root: optional override (same as set_repo_root) for one call.
    """
    if project_root is not None:
        set_repo_root(project_root)
    ordered: list[Path] = []
    file_macros: list[str] = []
    seen: set[Path] = set()
    parse_assignment_file(PROJECT / "Plex.qsf", seen, ordered, file_macros)
    parse_assignment_file(PROJECT / "files.qip", seen, ordered, file_macros)
    if macro_qsf is None:
        return ordered, file_macros
    # Prefer last-wins name=value map from check_define_parity for the gate QSF.
    from check_define_parity import discover_quartus_macros

    mapped = discover_quartus_macros(Path(macro_qsf))
    macros = [
        f"{name}={macro.value}"
        for name, macro in sorted(mapped.items())
        if name != "BUILD_DATE"
    ]
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
    gen_dir = ROOT / "build" / "rtl_lint_generated"
    gen_dir.mkdir(parents=True, exist_ok=True)
    (gen_dir / "build_id.v").write_text('`define BUILD_DATE "lint"\n')
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
module altera_pll (input refclk, input rst, output outclk_0, output outclk_1, output outclk_2, output locked); endmodule
module altddio_out #(parameter extend_oe_disable = "", parameter intended_device_family = "", parameter invert_output = "", parameter lpm_hint = "", parameter lpm_type = "", parameter oe_reg = "", parameter power_up_high = "", parameter width = 1) (input datain_h, input datain_l, input outclock, output dataout, input aclr, input aset, input oe, input outclocken, input sclr, input sset); endmodule
''')
    return stub


def _verilator_define_args(
    macros: list[str],
    *,
    macro_qsf: Path | None = None,
) -> list[str]:
    if macro_qsf is not None:
        return verilator_define_args(Path(macro_qsf))
    if macros:
        define_args: list[str] = []
        for raw in macros:
            raw = raw.strip()
            if not raw:
                continue
            if raw.startswith("-D"):
                define_args.append(raw)
            else:
                define_args.append(f"-D{raw}")
        return define_args
    return verilator_define_args()


def run_verilator(
    files: list[Path],
    macros: list[str],
    *,
    macro_qsf: Path | None = None,
    suppress_pinmissing: bool = True,
) -> tuple[int, str]:
    """Lint/elaborate files with product macros.

    Prefer explicit macro_qsf (fit gate). Else if macros list is provided as
    NAME=VALUE strings from discover_design, emit -D from that list (last-wins
    already applied). Else fall back to project Plex.qsf via verilator_define_args.

    suppress_pinmissing=True matches historical lint (ignores open optional pins).
    Connectivity sweeps set suppress_pinmissing=False so PINMISSING/UNDRIVEN fire.
    """
    stub = write_intel_stubs()
    ordered_files = sorted(files, key=lambda p: (is_excluded(p), rel(p) if p.exists() else str(p)))
    define_args = _verilator_define_args(macros, macro_qsf=macro_qsf)
    cmd = [
        str(ROOT / "scripts" / "run_verilator.sh"),
        "--lint-only", "-Wall", "-Wno-fatal",
        "-Wno-DECLFILENAME",
        "-Wno-MULTITOP", "-Wno-EOFNEWLINE", "-Wno-GENUNNAMED",
        f"-I{ROOT / 'build' / 'rtl_lint_generated'}",
        f"-I{PROJECT}", f"-I{PROJECT / 'sys'}", f"-I{PROJECT / 'rtl'}",
        str(stub),
    ]
    if suppress_pinmissing:
        # Historical product lint: open optional HPS pins are not fit blockers.
        cmd[4:4] = ["-Wno-PINCONNECTEMPTY", "-Wno-PINMISSING"]
    cmd = cmd + define_args + [str(p) for p in ordered_files]
    proc = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout


def run_connectivity_sweep(
    files: list[Path],
    macros: list[str],
    *,
    macro_qsf: Path | None = None,
) -> tuple[int, str, list[dict[str, str]]]:
    """Verilator PINMISSING + UNDRIVEN sweep over product hierarchy.

    Parent B20_UNCONNECTED_PRODUCER class (2026-08-03): correct producer + correct
    consumer that were never wired. Content-presence greps and ancestry checks are
    green; only a mechanical undriven/pinmissing pass catches it.

    Filter (noise control, not a weaken of the class):
      - PINMISSING kept when the *port declaration* lives under product rtl/
        (or Plex.sv). Vendor/sys optional pins (hps_io joysticks) are dropped.
      - UNDRIVEN kept when the undriven signal is declared in product rtl/ or
        Plex.sv.

    Limitation (false-negative twin — stated plainly): this sweep proves a net
    *has a driver* or a port *is present*. It does **not** prove the driver is
    the *intended* producer (e.g. content_fps=8'd24 while fabric_content_fps is
    driven but unused). Wrong-producer is a separate class.
    """
    owned = [p for p in files if p.exists() and not is_excluded(p)]
    rc, output = run_verilator(
        owned, macros, macro_qsf=macro_qsf, suppress_pinmissing=False
    )
    findings: list[dict[str, str]] = []
    lines = output.splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = WARN_RE.match(ln)
        if not m:
            i += 1
            continue
        kind, file_name, line_no, _col = m.groups()
        if kind not in {"PINMISSING", "UNDRIVEN"}:
            i += 1
            continue
        # PINMISSING secondary line: "... Location of port declaration"
        port_decl_path = ""
        pin_name = ""
        pm = re.search(r"Instance has missing pin: '([^']+)'", ln)
        if pm:
            pin_name = pm.group(1)
        um = re.search(r"Signal is not driven: '([^']+)'", ln)
        signal_name = um.group(1) if um else ""
        j = i + 1
        while j < len(lines) and lines[j].lstrip().startswith("..."):
            # continuation detail lines from verilator
            j += 1
        # Port declaration location is often on the next non-... indented path line
        k = i + 1
        while k < len(lines) and k < i + 6:
            loc = re.match(
                r"\s+(\S+\.(?:sv|v|svh)):(\d+):\d+:\s+\.\.\.\s+Location of port declaration",
                lines[k],
            )
            if loc:
                port_decl_path = loc.group(1)
                break
            # Sometimes the path is alone then "... Location"
            loc2 = re.match(r"\s+(\S+\.(?:sv|v|svh)):(\d+):\d+:", lines[k])
            if loc2 and k + 1 < len(lines) and "Location of port declaration" in lines[k + 1]:
                port_decl_path = loc2.group(1)
                break
            k += 1

        inst_path = file_name
        try:
            inst_p = Path(inst_path)
            if not inst_p.is_absolute():
                inst_p = (ROOT / inst_p).resolve()
            inst_rel = rel(inst_p)
        except Exception:
            inst_rel = inst_path

        def _is_product_rtl(path_s: str) -> bool:
            ps = path_s.replace("\\", "/")
            return (
                "/rtl/" in ps
                or ps.endswith("/Plex.sv")
                or ps.endswith("fpga/Plex_MiSTer/Plex.sv")
                or "/Plex_MiSTer/rtl/" in ps
            )

        keep = False
        if kind == "PINMISSING":
            decl = port_decl_path or ""
            decl_is_rtl = bool(decl) and (
                "/rtl/" in decl.replace("\\", "/")
                or decl.replace("\\", "/").endswith("/rtl")
            )
            # Only product-rtl *module* port decls (present_*/plex_*/ddr_*/…).
            # Drop sys/hps_io nested opens even when a secondary path line mis-parses.
            if not decl_is_rtl:
                keep = False
            else:
                # Parent class is unconnected *producer* outputs.
                direction = ""
                if pin_name:
                    try:
                        dpath = Path(decl)
                        if not dpath.is_absolute():
                            dpath = (ROOT / dpath).resolve()
                        dtxt = dpath.read_text(errors="ignore")
                        dm = re.search(
                            rf"\b(output|input|inout)\b[^;\n]{{0,120}}\b{re.escape(pin_name)}\b",
                            dtxt,
                        )
                        if dm:
                            direction = dm.group(1)
                    except OSError:
                        direction = ""
                # Keep output/inout PINMISSING. Skip input-only opens.
                keep = direction in {"output", "inout", ""}
        elif kind == "UNDRIVEN":
            keep = _is_product_rtl(inst_rel)

        if keep:
            findings.append(
                {
                    "kind": kind,
                    "inst_file": inst_rel,
                    "inst_line": line_no,
                    "pin": pin_name,
                    "signal": signal_name,
                    "port_decl": port_decl_path,
                    "raw": ln[:300],
                }
            )
        i += 1

    log = ROOT / "build" / "vl_connectivity_sweep.log"
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(output)
    except OSError:
        pass
    return rc, output, findings


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


def load_baseline(path: Path) -> tuple[dict[str, dict[str, int]], dict[str, list[str]], dict[str, str]]:
    data = json.loads(path.read_text())
    counts = {str(f): {str(k): int(v) for k, v in kinds.items()} for f, kinds in data.get("warnings", {}).items()}
    details = {str(f): [str(item) for item in items] for f, items in data.get("warning_details", {}).items()}
    waivers = {str(k): str(v) for k, v in data.get("justified_waivers", {}).items()}
    return counts, details, waivers


def unjustified_baseline_warnings(
    baseline_counts: dict[str, dict[str, int]], waivers: dict[str, str]
) -> list[str]:
    """Baseline entries with count>0 must carry a written justified_waivers reason.

    Mirrors timing_exclusion_baseline: an exception is only acceptable with a
    quoted justification. Empty warnings + empty waivers is the clean state.
    """
    missing: list[str] = []
    for file_name, kinds in sorted(baseline_counts.items()):
        for kind, count in sorted(kinds.items()):
            if int(count) <= 0:
                continue
            key = f"{file_name}:{kind}"
            # Accept exact key or any waiver key prefixed by file:kind
            if key in waivers and waivers[key].strip():
                continue
            if any(wk.startswith(key) and waivers[wk].strip() for wk in waivers):
                continue
            missing.append(
                f"{key} baseline count={count} lacks justified_waivers reason "
                f"(timing_exclusion bar: do not silence without written why)"
            )
    return missing


def write_baseline(path: Path, warnings: dict[str, dict[str, int]], details: dict[str, list[str]], files: set[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    prior: dict = {}
    if path.exists():
        try:
            prior = json.loads(path.read_text())
        except json.JSONDecodeError:
            prior = {}
    data = {
        "schema": "misterplex.rtl_lint_baseline.v2",
        "project": "fpga/Plex_MiSTer/Plex.qsf",
        "warning_classes": ["WIDTHTRUNC", "WIDTHEXPAND", "WIDTH", "UNSIGNED", "IMPLICIT*"],
        "excluded_prefixes": ["fpga/Plex_MiSTer/sys/", "fpga/Plex_MiSTer/rtl/pll/"],
        "files": sorted(files),
        "warnings": warnings,
        "warning_details": details,
        # Waivers require written justification (timing_exclusion bar). Prefer RTL casts.
        "justified_waivers": prior.get("justified_waivers", {}),
        "waiver_policy": prior.get(
            "waiver_policy",
            "Never silence WIDTH*/UNSIGNED without justified_waivers reason; prefer explicit RTL casts.",
        ),
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
    # The top wrapper pulls in MiSTer sys/generated context that Verilator cannot
    # fully elaborate without Intel libraries. Count any Plex.sv warnings emitted
    # before those context errors, but baseline the warning counts rather than
    # making existing context-elaboration errors block adoption.
    ignored_errors += top_ignored_errors + top_owned_errors
    if ignored_errors:
        print(f"RTL lint: ignored {len(ignored_errors)} vendor/generated context errors; see build/rtl_lint_verilator.log")
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
    baseline_counts, baseline_details, baseline_waivers = load_baseline(args.baseline)
    unjustified = unjustified_baseline_warnings(baseline_counts, baseline_waivers)
    if unjustified:
        print("RTL LINT ERROR: baseline warnings without justified_waivers:", file=sys.stderr)
        for item in unjustified:
            print(f"  {item}", file=sys.stderr)
        return 1
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
