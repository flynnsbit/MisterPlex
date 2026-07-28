#!/usr/bin/env python3
"""Post-fit decode-root oracle for W-AUDIT.

This is deliberately based on Quartus fit hierarchy, not RTL regex reachability.
It can report the fitted decode root or enforce either the legacy stub-root or
new h264_decode_core-root contract.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Row:
    entity: str
    full: str
    comb_aluts: float
    registers: float
    block_bits: float
    m10ks: float


def parse_number(text: str) -> float:
    m = re.search(r'-?\d+(?:,\d{3})*(?:\.\d+)?', text)
    return float(m.group(0).replace(',', '')) if m else 0.0


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip(';').split(';')]


def parse_fit(path: Path) -> list[Row]:
    if not path.exists():
        raise FileNotFoundError(path)
    rows: list[Row] = []
    header: list[str] | None = None
    for line in path.read_text(errors='ignore').splitlines():
        if 'Compilation Hierarchy Node' in line and 'Full Hierarchy Name' in line:
            header = [re.sub(r'\s+', ' ', c.strip()) for c in split_row(line)]
            continue
        if not header or not line.lstrip().startswith(';'):
            continue
        cells = split_row(line)
        if len(cells) != len(header) or not cells or not cells[0].startswith('|'):
            continue
        data = dict(zip(header, cells))
        entity = data.get('Entity Name', '')
        full = data.get('Full Hierarchy Name', '')
        if not entity or not full:
            continue
        rows.append(Row(
            entity=entity,
            full=full,
            comb_aluts=parse_number(data.get('Combinational ALUTs', '0')),
            registers=parse_number(data.get('Dedicated Logic Registers', '0')),
            block_bits=parse_number(data.get('Block Memory Bits', '0')),
            m10ks=parse_number(data.get('M10Ks', '0')),
        ))
    return rows


def find_entities(rows: list[Row], entity: str, under: str | None = None) -> list[Row]:
    return [r for r in rows if r.entity == entity and (not under or under in r.full)]


def format_found(label: str, found: list[Row]) -> None:
    print(f'W_AUDIT_POSTFIT_ENTITY {label} count={len(found)}')
    for row in found:
        print(f'  entity={row.entity} hierarchy={row.full} comb_aluts={row.comb_aluts:g} registers={row.registers:g} block_bits={row.block_bits:g} m10ks={row.m10ks:g}')


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--fit-rpt', type=Path, required=True)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument('--expect-core-root', action='store_true', help='Require h264_decode_core under stream_path and reject decode_stub')
    mode.add_argument('--expect-stub-root', action='store_true', help='Require decode_stub under stream_path and reject h264_decode_core')
    ap.add_argument('--stream-subtree', default='|stream_path:spath', help='Full-hierarchy substring identifying product stream_path subtree')
    args = ap.parse_args(argv[1:])

    try:
        rows = parse_fit(args.fit_rpt)
    except FileNotFoundError:
        print(f'W_AUDIT_POSTFIT_REFUSED missing fit report: {args.fit_rpt}', file=sys.stderr)
        return 4

    stream = find_entities(rows, 'stream_path')
    stub = find_entities(rows, 'decode_stub', args.stream_subtree)
    core = find_entities(rows, 'h264_decode_core', args.stream_subtree)
    top = find_entities(rows, 'h264_decode_top', args.stream_subtree)
    print(f'W_AUDIT_POSTFIT_REPORT fit_rpt={args.fit_rpt} rows={len(rows)} stream_subtree={args.stream_subtree}')
    format_found('stream_path', stream)
    format_found('decode_stub_under_stream', stub)
    format_found('h264_decode_core_under_stream', core)
    format_found('h264_decode_top_under_stream', top)

    errors: list[str] = []
    if args.expect_core_root:
        if not core:
            errors.append('h264_decode_core missing under product stream_path subtree')
        if stub:
            errors.append('retired decode_stub still present under product stream_path subtree')
    if args.expect_stub_root:
        if not stub:
            errors.append('decode_stub missing under product stream_path subtree')
        if core:
            errors.append('h264_decode_core unexpectedly present under product stream_path subtree')
    if errors:
        print('W_AUDIT_POSTFIT_REJECTED:', file=sys.stderr)
        for err in errors:
            print(f'  {err}', file=sys.stderr)
        return 1
    print('W_AUDIT_POSTFIT_OK report_complete')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
