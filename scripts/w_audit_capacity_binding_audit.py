#!/usr/bin/env python3
"""Audit the decode_stub capacity correction and line-buffer RBF binding semantics."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

DEFAULT_FIT = Path("/home/flynnsbit/Projects/mp-wt-integ/fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt")
DEFAULT_LINE_GATE = Path("/home/flynnsbit/Projects/MisterPlex/.worktrees/w-arm-idle-edge/scripts/check_fitted_line_buffer.py")


@dataclass(frozen=True)
class Row:
    entity: str
    full: str
    aluts: float
    regs: float
    bits: float
    m10k: float
    dsp: float


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
        rows.append(Row(
            entity=entity,
            full=full,
            aluts=parse_num(data.get("Combinational ALUTs", "0")),
            regs=parse_num(data.get("Dedicated Logic Registers", "0")),
            bits=parse_num(data.get("Block Memory Bits", "0")),
            m10k=parse_num(data.get("M10Ks", "0")),
            dsp=parse_num(data.get("DSP Blocks", "0")),
        ))
    return rows


def chain(full: str) -> list[str]:
    return [seg.split(":", 1)[0] for seg in full.strip("|").split("|") if seg]


def direct_children(rows: list[Row], parent: Row) -> list[Row]:
    prefix = parent.full + "|"
    parent_depth = len(chain(parent.full))
    return [r for r in rows if r.full.startswith(prefix) and len(chain(r.full)) == parent_depth + 1]


def md5(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def n(value: float) -> str:
    return str(int(value)) if value == int(value) else f"{value:g}"


def run_gate(gate: Path, report: Path, *extra: str) -> tuple[int, str]:
    p = subprocess.run(
        ["python3", str(gate), str(report), *extra],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return p.returncode, p.stdout


def summarize_gate(label: str, rc: int, out: str) -> None:
    flags = []
    if re.search(r"^UNBOUND:", out, flags=re.M):
        flags.append("UNBOUND")
    if re.search(r"^BOUND\b", out, flags=re.M):
        flags.append("BOUND")
    for name in ("BINDING_FAIL", "LINE_BUFFER_OK", "LINE_BUFFER_FAIL"):
        if re.search(rf"^{name}\b", out, flags=re.M):
            flags.append(name)
    print(f"LINE_GATE {label} rc={rc} flags={','.join(flags) if flags else '<none>'}")
    for line in out.splitlines():
        if any(tok in line for tok in ("UNBOUND", "BOUND", "BINDING_FAIL", "MATCH", "MISMATCH", "LINE_BUFFER_")):
            print(f"  {line}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fit-rpt", type=Path, default=DEFAULT_FIT)
    ap.add_argument("--line-gate", type=Path, default=DEFAULT_LINE_GATE)
    ap.add_argument("--expect-rbf-md5", default="fb4bad84")
    args = ap.parse_args()

    rows = parse_fit_rows(args.fit_rpt)
    print(f"FIT_RPT {args.fit_rpt}")
    print(f"FIT_ENTITY_ROWS {len(rows)}")
    sibling_rbf = args.fit_rpt.parent / "Plex.rbf"
    if sibling_rbf.exists():
        print(f"SIBLING_RBF_MD5 {md5(sibling_rbf)}")

    by_entity: dict[str, list[Row]] = {}
    for row in rows:
        by_entity.setdefault(row.entity, []).append(row)

    stubs = by_entity.get("decode_stub", [])
    if not stubs:
        print("DECODE_STUB absent")
    for stub in stubs:
        print(f"DECODE_STUB bits={n(stub.bits)} m10k={n(stub.m10k)} dsp={n(stub.dsp)} path={stub.full}")
        children = direct_children(rows, stub)
        for child in children:
            if child.bits or child.m10k or child.dsp:
                print(f"  STUB_DIRECT_CHILD entity={child.entity} bits={n(child.bits)} m10k={n(child.m10k)} dsp={n(child.dsp)} path={child.full}")
        ram_children = [c for c in children if c.entity == "altsyncram" and c.bits == stub.bits and c.m10k == stub.m10k]
        if ram_children:
            print("STUB_M10K_ACCOUNTING all_stub_m10k_in_single_direct_altsyncram=YES")
        else:
            print("STUB_M10K_ACCOUNTING all_stub_m10k_in_single_direct_altsyncram=NO")

    for entity in ("present_core", "ddr_frame_store", "frame_store"):
        hits = by_entity.get(entity, [])
        print(f"ENTITY {entity} count={len(hits)}")
        for hit in hits:
            print(f"  path={hit.full} bits={n(hit.bits)} m10k={n(hit.m10k)} dsp={n(hit.dsp)}")
    if any("present_core" in chain(r.full) for r in by_entity.get("ddr_frame_store", [])):
        print("PRESENT_PATH_FIT present_core_to_ddr_frame_store=YES")
    else:
        print("PRESENT_PATH_FIT present_core_to_ddr_frame_store=NO")

    if args.line_gate.exists():
        print(f"LINE_GATE_MODE {args.line_gate} mode={args.line_gate.stat().st_mode & 0o777:o}")
        rc, out = run_gate(args.line_gate, args.fit_rpt)
        summarize_gate("unbound", rc, out)
        rc, out = run_gate(args.line_gate, args.fit_rpt, "--expect-rbf-md5", args.expect_rbf_md5)
        summarize_gate("bound_expected", rc, out)
        rc, out = run_gate(args.line_gate, args.fit_rpt, "--expect-rbf-md5", "00000000")
        summarize_gate("bound_wrong", rc, out)
    else:
        print(f"LINE_GATE missing {args.line_gate}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
