#!/usr/bin/env python3
"""Attack post-fit hierarchy and files.qip evidence.

This is read-only against real project artifacts.  It writes one disposable
synthetic report under build/ to prove that check_quartus_fit_hierarchy.py is a
shape/resource parser, not a provenance oracle.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


DEFAULT_ROOT = Path("/home/flynnsbit/Projects/mp-wt-integ")
DEFAULT_FIT = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt"
DEFAULT_MAP = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.map.rpt"
DEFAULT_LOG = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/compile.log"


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return p.returncode, p.stdout


def git(root: Path, *args: str) -> str:
    rc, out = run(["git", "--no-pager", *args], root)
    return out.strip() if rc == 0 else f"UNKNOWN(rc={rc})"


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip(";").split(";")]


def parse_fit_entities(path: Path) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    header: list[str] | None = None
    for line in path.read_text(errors="ignore").splitlines():
        if "Compilation Hierarchy Node" in line and "Full Hierarchy Name" in line:
            header = [re.sub(r"\s+", " ", c.strip()) for c in split_row(line)]
            continue
        if not header or not line.lstrip().startswith(";"):
            continue
        cells = split_row(line)
        if len(cells) != len(header) or not cells or not cells[0].startswith("|"):
            continue
        data = dict(zip(header, cells))
        entity = data.get("Entity Name", "")
        full = data.get("Full Hierarchy Name", "")
        if entity and full:
            rows.append((entity, full))
    return rows


def active_qip_files(qip: Path) -> set[str]:
    active: set[str] = set()
    pat = re.compile(r"^\s*set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+(\S+)")
    for line in qip.read_text(errors="ignore").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = pat.search(line)
        if m:
            active.add(m.group(1))
    return active


def synthetic_fit_report() -> str:
    header = (
        "; Compilation Hierarchy Node ; ALMs needed [=A-B+C] ; [A] ALMs used in final placement ; "
        "[B] Estimate of ALMs recoverable by dense packing ; [C] Estimate of ALMs unavailable ; "
        "ALMs used for memory ; Combinational ALUTs ; Dedicated Logic Registers ; I/O Registers ; "
        "Block Memory Bits ; M10Ks ; DSP Blocks ; Pins ; Virtual Pins ; Full Hierarchy Name ; "
        "Entity Name ; Library Name ;\n"
    )
    rows = [
        (
            "|ddr_frame_store:fstore|",
            "|sys_top|emu:emu|present_core:present|ddr_frame_store:fstore",
            "ddr_frame_store",
            4757,
            2298,
            159744,
            96,
            6,
        ),
        (
            "|present_core:present|",
            "|sys_top|emu:emu|present_core:present",
            "present_core",
            4939,
            2514,
            225280,
            103,
            7,
        ),
        (
            "|stream_path:spath|",
            "|sys_top|emu:emu|stream_path:spath",
            "stream_path",
            11189,
            2707,
            2360260,
            291,
            34,
        ),
        (
            "|ddr_bitstream_reader:ddr_stream|",
            "|sys_top|emu:emu|stream_path:spath|ddr_bitstream_reader:ddr_stream",
            "ddr_bitstream_reader",
            930,
            686,
            0,
            0,
            0,
        ),
    ]
    out = [header]
    for node, full, entity, aluts, regs, bits, m10ks, dsps in rows:
        out.append(
            f"; {node} ; 1 ; 1 ; 0 ; 0 ; 0 ; {aluts} ; {regs} ; 0 ; {bits} ; "
            f"{m10ks} ; {dsps} ; 0 ; 0 ; {full} ; {entity} ; work ;\n"
        )
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--integ-root", type=Path, default=DEFAULT_ROOT)
    ap.add_argument("--fit-rpt", type=Path, default=DEFAULT_FIT)
    ap.add_argument("--map-rpt", type=Path, default=DEFAULT_MAP)
    ap.add_argument("--compile-log", type=Path, default=DEFAULT_LOG)
    args = ap.parse_args()

    audit_root = Path(__file__).resolve().parents[1]
    integ = args.integ_root
    print(f"INTEG_BRANCH {git(integ, 'rev-parse', '--abbrev-ref', 'HEAD')}")
    print(f"INTEG_COMMIT {git(integ, 'rev-parse', '--short', 'HEAD')}")
    print(f"FIT_RPT {args.fit_rpt}")

    rc, out = run(
        [
            "python3",
            str(integ / "scripts/check_quartus_fit_hierarchy.py"),
            "--fit-rpt",
            str(args.fit_rpt),
            "--map-rpt",
            str(args.map_rpt),
            "--log",
            str(args.compile_log),
        ],
        integ,
    )
    print(f"CASE default_postfit_hierarchy_on_fb4bad84 rc={rc}")
    for line in out.splitlines():
        if line.startswith("PASS ") or "| `stream_path`" in line or "| `ddr_frame_store`" in line:
            print(f"  {line}")

    rows = parse_fit_entities(args.fit_rpt)
    under_stream = lambda entity: [full for ent, full in rows if ent == entity and "|stream_path:spath" in full]
    stub = under_stream("decode_stub")
    core = under_stream("h264_decode_core")
    top = under_stream("h264_decode_top")
    print(f"CASE postfit_decode_root rows={len(rows)} decode_stub_under_stream={len(stub)} h264_decode_core_under_stream={len(core)} h264_decode_top_under_stream={len(top)}")
    for full in stub[:3]:
        print(f"  stub_hierarchy={full}")

    qip = integ / "fpga/Plex_MiSTer/files.qip"
    qip_files = active_qip_files(qip)
    core_in_qip = "rtl/h264_decode_core.sv" in qip_files
    stub_in_qip = "rtl/decode_stub.sv" in qip_files
    print(f"CASE qip_membership_not_enough h264_decode_core_active_qip={int(core_in_qip)} decode_stub_active_qip={int(stub_in_qip)} h264_decode_core_postfit_under_stream={len(core)}")

    qip_gate = integ / "scripts/check_qip_coverage.py"
    if qip_gate.exists():
        qip_rc, qip_out = run(["python3", str(qip_gate), "--require", "h264_decode_core"], integ)
        print(f"CASE current_check_qip_coverage rc={qip_rc}")
        for line in qip_out.splitlines():
            if (
                line.startswith("Scope:")
                or line.startswith("tracked but")
                or "NOT_COMPILED" in line
                or line.startswith("REQUIRED_")
                or line.startswith("QIP_COVERAGE_")
            ):
                print(f"  {line}")

    commented = "# set_global_assignment -name SYSTEMVERILOG_FILE rtl/w_audit_comment_only.sv\n"
    naive_contains = "rtl/w_audit_comment_only.sv" in commented
    active_contains = bool(active_qip_files_from_text(commented))
    print(f"CASE qip_comment_false_positive naive_text_contains={int(naive_contains)} active_assignment_contains={int(active_contains)}")

    wrong_dir = "set_global_assignment -name SYSTEMVERILOG_FILE rtl_old/h264_decode_core.sv\n"
    basename_match = "h264_decode_core.sv" == Path(wrong_dir.split()[-1]).name
    exact_path_match = "rtl/h264_decode_core.sv" in active_qip_files_from_text(wrong_dir)
    print(f"CASE qip_basename_false_positive basename_match={int(basename_match)} exact_rtl_path_match={int(exact_path_match)}")

    scratch = audit_root / "build/w_audit_postfit_hierarchy_attack"
    scratch.mkdir(parents=True, exist_ok=True)
    fake = scratch / "forged_fit_table.rpt"
    fake.write_text(synthetic_fit_report())
    try:
        fake_rc, fake_out = run(
            [
                "python3",
                str(integ / "scripts/check_quartus_fit_hierarchy.py"),
                "--fit-rpt",
                str(fake),
            ],
            integ,
        )
        print(f"CASE forged_non_quartus_report rc={fake_rc} path={fake}")
        for line in fake_out.splitlines():
            if line.startswith("PASS ") or line.startswith("FIT_HIERARCHY_REJECTED"):
                print(f"  {line}")
    finally:
        if fake.exists():
            fake.unlink()

    return 0


def active_qip_files_from_text(text: str) -> set[str]:
    tmp = Path("__not_used__")
    active: set[str] = set()
    pat = re.compile(r"^\s*set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+(\S+)")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = pat.search(line)
        if m:
            active.add(m.group(1))
    _ = tmp
    return active


if __name__ == "__main__":
    raise SystemExit(main())
