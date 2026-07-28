#!/usr/bin/env python3
"""Independent W-AUDIT parser for deployed-fit decode entity claims."""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


DEFAULT_ROOT = Path("/home/flynnsbit/Projects/mp-wt-integ")
DEFAULT_FIT = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt"
DEFAULT_LOG = DEFAULT_ROOT / "fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/compile.log"

WFIT_NAMED = [
    "decode_stub",
    "h264_decode_core",
    "h264_decode_top",
    "h264_decode_skeleton",
    "h264_dpb_one_ref",
    "h264_dpb_i420_addr",
    "h264_dpb_mb_write_addr",
    "h264_inter_mc_16x16",
    "h264_inter_mc_part",
    "h264_luma_qpel_block_16x16",
    "h264_chroma_epel_block_8x8",
    "h264_luma_ref_tap_addr",
    "h264_ref_clamp",
    "h264_intra_nb_ctx",
    "h264_mv_pred_16x16",
    "h264_mv_pred_part",
    "h264_luma_qpel_sample",
    "h264_chroma_epel_sample",
]


@dataclass(frozen=True)
class Row:
    entity: str
    full: str
    aluts: float
    regs: float
    block_bits: float
    m10ks: float
    dsps: float


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


def parse_num(text: str) -> float:
    m = re.search(r"-?\d+(?:,\d{3})*(?:\.\d+)?", text)
    return float(m.group(0).replace(",", "")) if m else 0.0


def parse_fit_rows(path: Path) -> list[Row]:
    rows: list[Row] = []
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
        if not entity or not full:
            continue
        rows.append(
            Row(
                entity=entity,
                full=full,
                aluts=parse_num(data.get("Combinational ALUTs", "0")),
                regs=parse_num(data.get("Dedicated Logic Registers", "0")),
                block_bits=parse_num(data.get("Block Memory Bits", "0")),
                m10ks=parse_num(data.get("M10Ks", "0")),
                dsps=parse_num(data.get("DSP Blocks", "0")),
            )
        )
    return rows


def parse_util(path: Path) -> dict[str, tuple[int, int, int]]:
    out: dict[str, tuple[int, int, int]] = {}
    pats = {
        "logic_alms": r"Logic utilization \(in ALMs\)\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
        "block_bits": r"Total block memory bits\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
        "m10k": r"Total RAM Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
        "dsp": r"Total DSP Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
    }
    text = path.read_text(errors="ignore")
    for name, pat in pats.items():
        m = re.search(pat, text)
        if m:
            out[name] = tuple(int(x.replace(",", "")) for x in m.groups())  # type: ignore[assignment]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--integ-root", type=Path, default=DEFAULT_ROOT)
    ap.add_argument("--fit-rpt", type=Path, default=DEFAULT_FIT)
    ap.add_argument("--compile-log", type=Path, default=DEFAULT_LOG)
    args = ap.parse_args()

    rows = parse_fit_rows(args.fit_rpt)
    util = parse_util(args.fit_rpt)
    by_entity: dict[str, list[Row]] = {}
    for row in rows:
        by_entity.setdefault(row.entity, []).append(row)

    print(f"BRANCH {git(args.integ_root, 'rev-parse', '--abbrev-ref', 'HEAD')}")
    print(f"COMMIT {git(args.integ_root, 'rev-parse', '--short', 'HEAD')}")
    print(f"FIT_RPT {args.fit_rpt}")
    print(f"FIT_ENTITY_ROWS {len(rows)}")
    for key, (used, total, pct) in util.items():
        print(f"DEVICE_UTIL {key} {used}/{total} pct={pct}")

    present_named = 0
    for mod in WFIT_NAMED:
        hits = by_entity.get(mod, [])
        if hits:
            present_named += 1
            only_stub = all("|decode_stub:stub" in r.full or r.entity == "decode_stub" for r in hits)
            print(f"NAMED_MODULE {mod} PRESENT count={len(hits)} only_stub={int(only_stub)}")
            for row in hits:
                print(
                    f"  hierarchy={row.full} aluts={row.aluts:g} regs={row.regs:g} "
                    f"block_bits={row.block_bits:g} m10ks={row.m10ks:g} dsps={row.dsps:g}"
                )
        else:
            print(f"NAMED_MODULE {mod} ABSENT count=0")
    print(f"NAMED_SUMMARY present={present_named} absent={len(WFIT_NAMED)-present_named} denominator={len(WFIT_NAMED)}")

    h264_rows = [r for r in rows if r.entity.startswith("h264_") or r.entity.startswith("h264")]
    print(f"H264_FIT_ROWS count={len(h264_rows)}")
    for row in h264_rows:
        print(
            f"  h264_entity={row.entity} hierarchy={row.full} aluts={row.aluts:g} "
            f"regs={row.regs:g} block_bits={row.block_bits:g} m10ks={row.m10ks:g} dsps={row.dsps:g}"
        )

    log_text = args.compile_log.read_text(errors="ignore") if args.compile_log.exists() else ""
    for mod in WFIT_NAMED:
        elaborated = bool(re.search(rf'Elaborating entity "{re.escape(mod)}"', log_text))
        fitted = bool(by_entity.get(mod))
        if elaborated and not fitted:
            print(f"ELABORATED_BUT_NOT_FIT {mod}")

    stub = by_entity.get("decode_stub", [])
    if stub:
        s = stub[0]
        print(
            "DECODE_STUB_RESOURCE "
            f"aluts={s.aluts:g} regs={s.regs:g} block_bits={s.block_bits:g} "
            f"m10ks={s.m10ks:g} dsps={s.dsps:g}"
        )
        if "m10k" in util:
            used, total, _ = util["m10k"]
            print(f"DECODE_STUB_M10K_SHARE used_pct={100*s.m10ks/used:.1f} device_pct={100*s.m10ks/total:.1f}")
        if "block_bits" in util:
            used, total, _ = util["block_bits"]
            print(f"DECODE_STUB_BLOCK_BITS_SHARE used_pct={100*s.block_bits/used:.1f} device_pct={100*s.block_bits/total:.1f}")
        if "dsp" in util:
            used, total, _ = util["dsp"]
            print(f"DECODE_STUB_DSP_SHARE used_pct={100*s.dsps/used:.1f} device_pct={100*s.dsps/total:.1f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
