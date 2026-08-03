#!/usr/bin/env python3
"""Gate: fabric H.264 inventory must match a fitted Plex.fit.rpt.

Hand-maintained resource tables drift (see the retracted "46% M10K free"
claim that used bit-arithmetic in the wrong unit). This script:

1. Parses Quartus hierarchy + resource totals from a real or excerpt fit.rpt
2. Checks must-present entities (ALMs within tolerance) and must-absent entities
3. Optionally requires docs/phase3-decode.md to embed the regenerated table
4. Distinguishes stripped-unreachable vs flattened-into-parent (hybrid_mb_own)

Exit codes:
  0 PASS
  1 inventory / doc mismatch (real fail)
  2 bad args / fixture schema
  4 missing fit report
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from check_quartus_fit_hierarchy import HierRow, parse_hierarchy_report, parse_number  # noqa: E402

DEFAULT_FIXTURE = ROOT / "tests" / "fixtures" / "fabric_decode_inventory.json"
DEFAULT_DOC = ROOT / "docs" / "phase3-decode.md"
DOC_BEGIN = "<!-- FABRIC_DECODE_INVENTORY_BEGIN -->"
DOC_END = "<!-- FABRIC_DECODE_INVENTORY_END -->"


def parse_fit_totals(path: Path) -> dict[str, float]:
    """Extract design-wide resource totals from a fit.rpt (or excerpt)."""
    text = path.read_text(errors="ignore")
    totals: dict[str, float] = {}

    def grab(pattern: str, key: str, group: int = 1) -> None:
        m = re.search(pattern, text)
        if m:
            totals[key] = parse_number(m.group(group))

    grab(
        r"Logic utilization \(in ALMs\)\s*;\s*([\d,]+(?:\.\d+)?)\s*/\s*([\d,]+)",
        "alm_used",
    )
    m = re.search(
        r"Logic utilization \(in ALMs\)\s*;\s*([\d,]+(?:\.\d+)?)\s*/\s*([\d,]+)",
        text,
    )
    if m:
        totals["alm_used"] = parse_number(m.group(1))
        totals["alm_total"] = parse_number(m.group(2))
    grab(r";\s*Total registers\s*;\s*([\d,]+)", "registers")
    m = re.search(
        r"Total block memory bits\s*;\s*([\d,]+)\s*/\s*([\d,]+)",
        text,
    )
    if m:
        totals["block_bits_used"] = parse_number(m.group(1))
        totals["block_bits_total"] = parse_number(m.group(2))
    m = re.search(r"Total RAM Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)", text)
    if m:
        totals["ram_blocks_used"] = parse_number(m.group(1))
        totals["ram_blocks_total"] = parse_number(m.group(2))
    m = re.search(r"Total DSP Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)", text)
    if m:
        totals["dsp_used"] = parse_number(m.group(1))
        totals["dsp_total"] = parse_number(m.group(2))
    return totals


def find_entity(rows: list[HierRow], entity: str, hierarchy_contains: str = "") -> HierRow | None:
    cands = [
        r
        for r in rows
        if r.entity == entity
        and (not hierarchy_contains or hierarchy_contains in r.full_hierarchy)
    ]
    if not cands:
        return None
    return max(cands, key=lambda r: r.alms_needed)


def entity_present(rows: list[HierRow], entity: str) -> bool:
    return any(r.entity == entity for r in rows)


def format_inventory_table(
    rows: list[HierRow],
    present_specs: list[dict],
    absent_entities: list[str],
    totals: dict[str, float],
    residual_own_alms: float | None,
) -> str:
    lines = [
        f"| fit totals | ALM **{int(totals.get('alm_used', 0)):,}** / "
        f"{int(totals.get('alm_total', 0)):,} · "
        f"regs **{int(totals.get('registers', 0)):,}** · "
        f"RAM blocks **{int(totals.get('ram_blocks_used', 0))}** / "
        f"{int(totals.get('ram_blocks_total', 0))} · "
        f"DSP **{int(totals.get('dsp_used', 0))}** / "
        f"{int(totals.get('dsp_total', 0))} · "
        f"block bits **{int(totals.get('block_bits_used', 0)):,}** / "
        f"{int(totals.get('block_bits_total', 0)):,} |",
        "",
        "| entity | ALMs needed | status |",
        "|---|---:|---|",
    ]
    for spec in present_specs:
        ent = str(spec["entity"])
        contains = str(spec.get("hierarchy_contains", ""))
        row = find_entity(rows, ent, contains)
        if row:
            lines.append(f"| `{ent}` | {row.alms_needed:g} | PRESENT |")
        else:
            lines.append(f"| `{ent}` | — | MISSING |")
    if residual_own_alms is not None:
        lines.append(
            f"| `decode_stub` residual (own + flattened leaves e.g. `h264_hybrid_mb_own`) | "
            f"{residual_own_alms:g} | FLATTENED_INTO_PARENT |"
        )
    for ent in absent_entities:
        st = "ABSENT_OK" if not entity_present(rows, ent) else "UNEXPECTED_PRESENT"
        lines.append(f"| `{ent}` | 0 | {st} |")
    return "\n".join(lines) + "\n"


def decode_stub_residual(rows: list[HierRow]) -> float | None:
    stub = find_entity(rows, "decode_stub", "decode_stub:stub")
    if not stub:
        return None
    # Direct children: one hierarchy segment after decode_stub:stub|
    direct_sum = 0.0
    for r in rows:
        if "decode_stub:stub|" not in r.full_hierarchy:
            continue
        tail = r.full_hierarchy.split("decode_stub:stub|", 1)[1]
        if "|" in tail:
            continue  # nested under a direct child
        direct_sum += r.alms_needed
    return round(stub.alms_needed - direct_sum, 1)


def check_totals(totals: dict[str, float], expect: dict, errors: list[str]) -> None:
    mapping = [
        ("alm_used", "alm_used", 0),
        ("alm_total", "alm_total", 0),
        ("registers", "registers", 0),
        ("ram_blocks_used", "ram_blocks_used", 0),
        ("ram_blocks_total", "ram_blocks_total", 0),
        ("dsp_used", "dsp_used", 0),
        ("dsp_total", "dsp_total", 0),
        ("block_bits_used", "block_bits_used", 0),
        ("block_bits_total", "block_bits_total", 0),
    ]
    for key, exp_key, _ in mapping:
        if exp_key not in expect:
            continue
        got = totals.get(key)
        exp = float(expect[exp_key])
        if got is None:
            errors.append(f"fit totals missing {key}")
            continue
        if abs(got - exp) > 0.5:
            errors.append(f"fit totals {key}: got {got:g} want {exp:g}")


def check_present(rows: list[HierRow], specs: list[dict], errors: list[str]) -> None:
    for spec in specs:
        ent = str(spec["entity"])
        contains = str(spec.get("hierarchy_contains", ""))
        row = find_entity(rows, ent, contains)
        if not row:
            errors.append(f"must_present missing entity={ent} contains={contains!r}")
            continue
        exp = float(spec["alm"])
        tol = float(spec.get("alm_tol", 0.5))
        if abs(row.alms_needed - exp) > tol:
            errors.append(
                f"{ent}: ALMs {row.alms_needed:g} outside {exp:g} ± {tol:g}"
            )


def check_absent(rows: list[HierRow], entities: list[str], errors: list[str]) -> None:
    for ent in entities:
        if entity_present(rows, ent):
            hits = [r.full_hierarchy for r in rows if r.entity == ent][:3]
            errors.append(f"must_absent but PRESENT entity={ent} rows={hits}")


def check_flattened(doc_text: str, specs: list[dict], errors: list[str]) -> None:
    """Flattened modules must be named as flattened, never as 'absent/stripped'."""
    for spec in specs:
        ent = str(spec["entity"])
        # Forbid claiming the flattened entity is stripped/unreachable/absent in doc.
        bad = re.compile(
            rf"`?{re.escape(ent)}`?.*\b(stripped|unreachable|absent|not in (the )?fit|"
            rf"zero hierarchy|no hierarchy)\b",
            re.I,
        )
        good = re.compile(
            rf"`?{re.escape(ent)}`?.*\b(flatten|flattened|leaf|into\s+`?decode_stub)\b",
            re.I,
        )
        if bad.search(doc_text) and not good.search(doc_text):
            errors.append(
                f"doc misclassifies flattened entity {ent} as stripped/absent without "
                f"flatten wording"
            )
        require = str(spec.get("doc_must_contain", ""))
        if require and require not in doc_text:
            errors.append(f"doc missing required flattened note for {ent}: {require!r}")


def extract_doc_block(doc_text: str) -> str | None:
    if DOC_BEGIN not in doc_text or DOC_END not in doc_text:
        return None
    return doc_text.split(DOC_BEGIN, 1)[1].split(DOC_END, 1)[0].strip()


def normalize_table(s: str) -> str:
    lines = []
    for line in s.splitlines():
        t = line.strip()
        if not t or t.startswith("<!--"):
            continue
        # collapse whitespace inside cells
        t = re.sub(r"\s+", " ", t)
        lines.append(t)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fit-rpt", type=Path, required=True)
    ap.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    ap.add_argument("--doc", type=Path, default=None, help="phase3-decode.md to cross-check")
    ap.add_argument(
        "--require-doc",
        action="store_true",
        help="Fail if --doc missing inventory markers or table disagrees",
    )
    ap.add_argument(
        "--emit-table",
        action="store_true",
        help="Print regenerated markdown table (for doc refresh) and exit 0",
    )
    ap.add_argument(
        "--skip-totals",
        action="store_true",
        help="Skip design-wide totals (for hierarchy-only synthetic red fixtures)",
    )
    args = ap.parse_args(argv)

    if not args.fit_rpt.exists():
        print(f"FABRIC_INV_REFUSED(exit=4): missing fit rpt {args.fit_rpt}", file=sys.stderr)
        return 4
    if not args.fixture.exists():
        print(f"FABRIC_INV_REFUSED(exit=2): missing fixture {args.fixture}", file=sys.stderr)
        return 2

    try:
        fixture = json.loads(args.fixture.read_text())
    except json.JSONDecodeError as e:
        print(f"FABRIC_INV_REFUSED(exit=2): fixture JSON: {e}", file=sys.stderr)
        return 2
    if fixture.get("schema") != "misterplex.fabric_decode_inventory.v1":
        print("FABRIC_INV_REFUSED(exit=2): bad schema", file=sys.stderr)
        return 2

    rows = parse_hierarchy_report(args.fit_rpt)
    totals = parse_fit_totals(args.fit_rpt)
    present_specs = list(fixture.get("must_present", []))
    absent = [str(x) for x in fixture.get("must_absent", [])]
    flattened = list(fixture.get("must_flattened_not_absent", []))
    residual = decode_stub_residual(rows)

    table = format_inventory_table(rows, present_specs, absent, totals, residual)
    if args.emit_table:
        print(DOC_BEGIN)
        print(table.rstrip())
        print(DOC_END)
        return 0

    errors: list[str] = []
    if not args.skip_totals:
        check_totals(totals, fixture.get("fit_totals", {}), errors)
    check_present(rows, present_specs, errors)
    check_absent(rows, absent, errors)

    # Residual own ALMs (decode_stub minus direct children) — optional
    exp_res = fixture.get("decode_stub_residual_own_alms")
    if exp_res is not None and residual is not None:
        tol = float(fixture.get("decode_stub_residual_tol", 1.0))
        if abs(residual - float(exp_res)) > tol:
            errors.append(
                f"decode_stub residual own ALMs {residual:g} outside {exp_res} ± {tol}"
            )

    doc_path = args.doc
    if args.require_doc and doc_path is None:
        doc_path = DEFAULT_DOC
    if doc_path is not None:
        if not doc_path.exists():
            errors.append(f"doc missing: {doc_path}")
        else:
            doc_text = doc_path.read_text(errors="ignore")
            check_flattened(doc_text, flattened, errors)
            # Hard requirements from fixture
            for needle in fixture.get("doc_must_contain", []):
                if str(needle) not in doc_text:
                    errors.append(f"doc missing required string: {needle!r}")
            for needle in fixture.get("doc_must_not_contain", []):
                if str(needle) in doc_text:
                    errors.append(f"doc contains forbidden string: {needle!r}")
            if args.require_doc:
                block = extract_doc_block(doc_text)
                if block is None:
                    errors.append(
                        f"doc missing {DOC_BEGIN} ... {DOC_END} inventory markers"
                    )
                else:
                    # Compare entity/ALM rows for must_present only (stable core)
                    regen_lines = [
                        ln
                        for ln in normalize_table(table).splitlines()
                        if ln.startswith("| `") and "PRESENT" in ln
                    ]
                    doc_lines = [
                        ln
                        for ln in normalize_table(block).splitlines()
                        if ln.startswith("| `") and "PRESENT" in ln
                    ]
                    if regen_lines != doc_lines:
                        errors.append(
                            "doc inventory PRESENT rows disagree with fit.rpt regeneration"
                        )
                        # Show first diff
                        for a, b in zip(regen_lines, doc_lines):
                            if a != b:
                                errors.append(f"  fit: {a}")
                                errors.append(f"  doc: {b}")
                                break
                        if len(regen_lines) != len(doc_lines):
                            errors.append(
                                f"  present row count fit={len(regen_lines)} doc={len(doc_lines)}"
                            )

    print("FABRIC_DECODE_INVENTORY_TABLE_BEGIN")
    print(table.rstrip())
    print("FABRIC_DECODE_INVENTORY_TABLE_END")
    if residual is not None:
        print(f"decode_stub_residual_own_alms={residual:g}")

    if errors:
        print("FABRIC_DECODE_INVENTORY_FAIL:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    print("PASS fabric_decode_inventory: fit.rpt matches fixture"
          + (" and doc" if doc_path is not None and args.require_doc else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
