#!/usr/bin/env python3
"""Attack decode-core survival and the fit-report entity-table denominator."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path

FB_FIT = Path("/home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt")
FB_LOG = Path("/home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/compile.log")
PREFIT_MAP = Path("/home/flynnsbit/Projects/mp-wt-integ/.copilot-logs/prefit-decode-2f165ed/Plex.map.rpt")
PREFIT_LOG = Path("/home/flynnsbit/Projects/mp-wt-integ/.copilot-logs/prefit-decode-2f165ed/prefit.log")
DECODE_ROOT = Path("/home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27")
STREAM = DECODE_ROOT / "fpga/Plex_MiSTer/rtl/stream_path.sv"
CORE = DECODE_ROOT / "fpga/Plex_MiSTer/rtl/h264_decode_core.sv"
QIP = DECODE_ROOT / "fpga/Plex_MiSTer/files.qip"

TARGETS = {
    "h264_decode_core",
    "h264_decode_top",
    "h264_intra_nb_ctx",
    "h264_decode_skeleton",
}


@dataclass(frozen=True)
class Row:
    line: int
    entity: str
    full: str
    aluts: float
    regs: float
    bits: float
    m10k: float
    dsp: float


@dataclass(frozen=True)
class Table:
    rows: list[Row]
    header_line: int
    first_row_line: int
    end_line: int
    trailing_entity_shaped: int
    header_count: int


def cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip(";").split(";")]


def num(text: str) -> float:
    m = re.search(r"-?\d+(?:,\d{3})*(?:\.\d+)?", text)
    return float(m.group(0).replace(",", "")) if m else 0.0


def parse_table(path: Path) -> Table:
    lines = path.read_text(errors="ignore").splitlines()
    header = None
    header_cells: list[str] | None = None
    rows: list[Row] = []
    end = 0
    header_count = 0
    for i, line in enumerate(lines, 1):
        if "Compilation Hierarchy Node" in line and "Full Hierarchy Name" in line:
            header_count += 1
            if header is None:
                header = i
                header_cells = [re.sub(r"\s+", " ", c.strip()) for c in cells(line)]
            continue
        if header is None or header_cells is None:
            continue
        cs = cells(line)
        if line.lstrip().startswith(";") and cs and cs[0].startswith("|"):
            if len(cs) != len(header_cells):
                raise RuntimeError(f"malformed entity row at {path}:{i}")
            data = dict(zip(header_cells, cs))
            rows.append(Row(
                line=i,
                entity=data.get("Entity Name", ""),
                full=data.get("Full Hierarchy Name", ""),
                aluts=num(data.get("Combinational ALUTs", "0")),
                regs=num(data.get("Dedicated Logic Registers", "0")),
                bits=num(data.get("Block Memory Bits", "0")),
                m10k=num(data.get("M10Ks", "0")),
                dsp=num(data.get("DSP Blocks", "0")),
            ))
        elif rows:
            end = i - 1
            break
    if header is None or not rows:
        raise RuntimeError(f"no bounded entity table in {path}")
    trailing = 0
    for line in lines[end:]:
        cs = cells(line)
        if line.lstrip().startswith(";") and cs and cs[0].startswith("|"):
            trailing += 1
    return Table(rows, header, rows[0].line, end, trailing, header_count)


def parse_summary_util(path: Path) -> dict[str, int]:
    text = path.read_text(errors="ignore")
    pats = {
        "bits": r"Total block memory bits\s*;\s*([\d,]+)\s*/",
        "m10k": r"Total RAM Blocks\s*;\s*([\d,]+)\s*/",
        "dsp": r"Total DSP Blocks\s*;\s*([\d,]+)\s*/",
    }
    out: dict[str, int] = {}
    for k, pat in pats.items():
        m = re.search(pat, text)
        if m:
            out[k] = int(m.group(1).replace(",", ""))
    return out


def analyze_report(label: str, report: Path) -> None:
    table = parse_table(report)
    root = table.rows[0]
    util = parse_summary_util(report)
    print(f"REPORT {label} {report}")
    print(
        f"  ENTITY_TABLE rows={len(table.rows)} header_line={table.header_line} "
        f"first_row={table.first_row_line} end_line={table.end_line} "
        f"headers={table.header_count} trailing_entity_rows={table.trailing_entity_shaped}"
    )
    print(
        f"  ROOT_ROW entity={root.entity} path={root.full} bits={root.bits:g} "
        f"m10k={root.m10k:g} dsp={root.dsp:g} summary_bits={util.get('bits', '<missing>')} "
        f"summary_m10k={util.get('m10k', '<missing>')} summary_dsp={util.get('dsp', '<missing>')}"
    )
    product = [r for r in table.rows if "product_decode_core" in r.full]
    print(f"  PRODUCT_DECODE_CORE_PATH_ROWS {len(product)}")
    for target in sorted(TARGETS):
        hits = [r for r in table.rows if r.entity == target or target in r.full]
        print(f"  TARGET {target} rows={len(hits)}")
        for r in hits[:8]:
            print(f"    line={r.line} entity={r.entity} path={r.full} aluts={r.aluts:g} regs={r.regs:g} bits={r.bits:g} m10k={r.m10k:g} dsp={r.dsp:g}")
    h264 = [r for r in table.rows if r.entity.startswith("h264")]
    only_stub = all("|decode_stub:" in r.full for r in h264)
    print(f"  H264_ROWS count={len(h264)} only_under_decode_stub={int(only_stub)} entities={','.join(sorted({r.entity for r in h264}))}")
    for r in h264:
        print(f"    H264_ROW entity={r.entity} path={r.full}")


def analyze_log(label: str, log: Path) -> None:
    text = log.read_text(errors="ignore")
    print(f"LOG {label} {log}")
    for pat_label, pat in [
        ("found_core_source", r"Found entity 1: h264_decode_core"),
        ("elab_core", r'Elaborating entity "h264_decode_core"'),
        ("elab_skeleton", r'Elaborating entity "h264_decode_skeleton"'),
        ("keep_core_inputs_never_read", r'object "_keep_decode_core_inputs" assigned a value but never read'),
        ("stream_keep_never_read", r'object "_keep" assigned a value but never read'),
    ]:
        hits = [(i, line.strip()) for i, line in enumerate(text.splitlines(), 1) if re.search(pat, line)]
        print(f"  {pat_label} count={len(hits)}")
        for i, line in hits[:8]:
            print(f"    {i}: {line}")


def source_refs() -> None:
    print(f"SOURCE {DECODE_ROOT} stream={STREAM}")
    s = STREAM.read_text(errors="ignore")
    for token in [
        "core_dpb_wr_en", "core_dpb_wr_addr", "core_dpb_wr_data", "core_dpb_rd_en",
        "core_dpb_rd_addr", "core_frame_done", "core_frame_mb_count", "core_rbsp_request_valid",
        "core_rbsp_request_offset", "core_busy", "core_decode_state", "core_current_mb_addr", "core_error",
    ]:
        refs = [(i, line.strip()) for i, line in enumerate(s.splitlines(), 1) if token in line]
        print(f"  STREAM_REF {token} count={len(refs)} lines={','.join(str(i) for i,_ in refs)}")
    core_text = CORE.read_text(errors="ignore")
    keep_refs = [(i, line.strip()) for i, line in enumerate(core_text.splitlines(), 1) if "_keep_decode_core_inputs" in line]
    print(f"  CORE_KEEP_REFS count={len(keep_refs)} lines={','.join(str(i) for i,_ in keep_refs)}")
    qip = QIP.read_text(errors="ignore")
    for modfile in ["h264_decode_core.sv", "h264_decode_top.sv", "h264_intra_nb_ctx.sv", "h264_decode_skeleton.sv"]:
        print(f"  QIP_CONTAINS {modfile} {int(modfile in qip)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fb-fit", type=Path, default=FB_FIT)
    ap.add_argument("--fb-log", type=Path, default=FB_LOG)
    ap.add_argument("--prefit-map", type=Path, default=PREFIT_MAP)
    ap.add_argument("--prefit-log", type=Path, default=PREFIT_LOG)
    args = ap.parse_args()
    analyze_report("fb4bad84_fit", args.fb_fit)
    analyze_log("fb4bad84_fit_compile", args.fb_log)
    analyze_report("prefit_decode_2f165ed_map", args.prefit_map)
    analyze_log("prefit_decode_2f165ed", args.prefit_log)
    source_refs()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
