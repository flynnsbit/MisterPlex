#!/usr/bin/env python3
"""Gate that the assembled product H.264 decoder has every required capability."""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import check_rtl_module_instantiations as rtl  # noqa: E402

CAPABILITY_FILE = rtl.RTL_DIR / "decode_capability_modules.txt"
PRODUCT_CONFIGS = (
    ("DECODE_REAL_INTRA=0", {"DECODE_REAL_INTRA": 0}),
    ("DECODE_REAL_INTRA=1", {"DECODE_REAL_INTRA": 1}),
)
REQUIRED_CATEGORIES = (
    "bitstream_entropy",
    "residual_dequant_transform",
    "intra_prediction",
    "inter_prediction_mc_subpel",
    "mv_prediction",
    "dpb_reference_management",
    "deblocking_writeback",
)
LINEAGE_ROOTS = (
    "decode_stub",
    "h264_decode_top",
    "h264_decode_core",
    "h264_decode_skeleton",
)


@dataclass(frozen=True)
class Capability:
    name: str
    modules: tuple[str, ...]
    reason: str


def fail(msg: str) -> None:
    print(f"DECODE_COMPLETENESS_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def parse_capabilities() -> dict[str, Capability]:
    if not CAPABILITY_FILE.exists():
        fail(f"missing decode capability manifest {CAPABILITY_FILE.relative_to(ROOT)}")
    out: dict[str, Capability] = {}
    for lineno, raw in enumerate(CAPABILITY_FILE.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split(":", 2)]
        if len(parts) != 3:
            fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: expected 'category: module,module: reason'")
        name, module_text, reason = parts
        if name not in REQUIRED_CATEGORIES:
            fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: unknown category {name!r}")
        modules = tuple(m.strip() for m in module_text.split(",") if m.strip())
        if not modules:
            fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: category {name} has no modules")
        for module in modules:
            if not re.fullmatch(r"[A-Za-z_]\w*", module):
                fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: invalid module {module!r}")
        if len(set(modules)) != len(modules):
            fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: duplicate module in {name}")
        if len(reason) < 12:
            fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: reason too vague for {name}")
        if name in out:
            fail(f"{CAPABILITY_FILE.relative_to(ROOT)}:{lineno}: duplicate category {name}")
        out[name] = Capability(name, modules, reason)
    missing = [name for name in REQUIRED_CATEGORIES if name not in out]
    if missing:
        fail("capability manifest missing required categories: " + ", ".join(missing))
    return out


def descendants(root: str, graph: dict[str, set[str]]) -> set[str]:
    if root not in graph:
        return set()
    seen: set[str] = set()
    stack = [root]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        stack.extend(sorted(graph.get(name, set()) - seen))
    return seen


def check_capabilities(label: str, reachable: set[str], caps: dict[str, Capability]) -> tuple[bool, list[str]]:
    missing_categories: list[str] = []
    for category in REQUIRED_CATEGORIES:
        cap = caps[category]
        present = [module for module in cap.modules if module in reachable]
        missing = [module for module in cap.modules if module not in reachable]
        status = "PASS" if not missing else "FAIL"
        if missing:
            missing_categories.append(category)
        print(
            f"DECODE_CAPABILITY config={label} category={category} status={status} "
            f"present={','.join(present) if present else '<none>'} "
            f"missing={','.join(missing) if missing else '<none>'}"
        )
    return not missing_categories, missing_categories


def classify_lineage(root: str, product_roots_by_config: dict[str, set[str]]) -> str:
    configs = [label for label, roots in product_roots_by_config.items() if root in roots]
    if configs:
        return "product:" + ",".join(configs)
    if root == "h264_decode_core":
        return "dead/staged: bench-only partial product datapath, not instantiated by stream_path"
    if root == "h264_decode_skeleton":
        return "dead/resource-estimation: bench-only fitter skeleton, explicitly not a decoder"
    return "dead: not product-reachable in checked configurations"


def product_mode(caps: dict[str, Capability]) -> int:
    rtl_paths = rtl.git_files("fpga/Plex_MiSTer/rtl")
    paths = rtl_paths + [rtl.PRODUCT_TOP]
    modules, _, _ = rtl.build_reachable(paths, {"DECODE_REAL_INTRA": 0})
    rtl_modules = {name for name, mod in modules.items() if rtl.RTL_DIR in mod.path.parents or mod.path == rtl.RTL_DIR}
    declared_modules = sorted({module for cap in caps.values() for module in cap.modules})
    unknown = [module for module in declared_modules if module not in rtl_modules]
    if unknown:
        fail("decode capability manifest names modules that do not exist: " + ", ".join(unknown))

    print(
        "Scope: decode-completeness product_configs=DECODE_REAL_INTRA=0,DECODE_REAL_INTRA=1 "
        f"required_categories={len(REQUIRED_CATEGORIES)} manifest={CAPABILITY_FILE.relative_to(ROOT)}"
    )

    all_ok = True
    product_roots_by_config: dict[str, set[str]] = {}
    for label, overrides in PRODUCT_CONFIGS:
        _, graph, reachable = rtl.build_reachable(paths, overrides)
        rtl_reachable = reachable & rtl_modules
        product_roots = {root for root in LINEAGE_ROOTS if root in rtl_reachable}
        product_roots_by_config[label] = product_roots
        ok, missing_categories = check_capabilities(label, rtl_reachable, caps)
        all_ok = all_ok and ok
        print(
            f"DECODE_COMPLETENESS_CONFIG config={label} status={'PASS' if ok else 'FAIL'} "
            f"reachable={len(rtl_reachable)} decode_roots={','.join(sorted(product_roots)) if product_roots else '<none>'} "
            f"missing_categories={','.join(missing_categories) if missing_categories else '<none>'}"
        )

    _, lineage_graph, _ = rtl.build_reachable(paths, {"DECODE_REAL_INTRA": 0})
    print(f"DECODE_LINEAGE_COUNT count={len(LINEAGE_ROOTS)}")
    for root in LINEAGE_ROOTS:
        reach = descendants(root, lineage_graph) & rtl_modules
        present_categories = []
        for category in REQUIRED_CATEGORIES:
            cap = caps[category]
            if all(module in reach for module in cap.modules):
                present_categories.append(category)
        direct = sorted(lineage_graph.get(root, set()) & rtl_modules)
        print(
            f"DECODE_LINEAGE root={root} classification={classify_lineage(root, product_roots_by_config)} "
            f"descendants={len(reach)} direct_children={','.join(direct) if direct else '<none>'} "
            f"complete_categories={','.join(present_categories) if present_categories else '<none>'}"
        )

    if not all_ok:
        print("DECODE_COMPLETENESS_FAIL current product decode configurations are incomplete")
        return 1
    print("DECODE_COMPLETENESS_OK all product decode configurations complete")
    return 0


def synthetic_mode(caps: dict[str, Capability], drop_category: str | None) -> int:
    if drop_category and drop_category not in caps:
        fail(f"unknown synthetic drop category {drop_category!r}")
    print(
        "Scope: decode-completeness synthetic "
        f"required_categories={len(REQUIRED_CATEGORIES)} drop_category={drop_category or '<none>'}"
    )
    reachable = {"synthetic_decode_top"}
    for category in REQUIRED_CATEGORIES:
        if category == drop_category:
            continue
        reachable.update(caps[category].modules)
    ok, missing_categories = check_capabilities("synthetic", reachable, caps)
    print(
        f"DECODE_COMPLETENESS_CONFIG config=synthetic status={'PASS' if ok else 'FAIL'} "
        f"reachable={len(reachable)} decode_roots=synthetic_decode_top "
        f"missing_categories={','.join(missing_categories) if missing_categories else '<none>'}"
    )
    if ok:
        print("DECODE_COMPLETENESS_OK synthetic complete graph satisfies every category")
        return 0
    print("DECODE_COMPLETENESS_FAIL synthetic graph missing required categories")
    return 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--synthetic-complete", action="store_true", help="Check a synthetic graph containing all mapped capability modules")
    ap.add_argument("--synthetic-drop-category", help="With --synthetic-complete, remove one category to prove red")
    args = ap.parse_args(argv)
    caps = parse_capabilities()
    if args.synthetic_complete or args.synthetic_drop_category:
        return synthetic_mode(caps, args.synthetic_drop_category)
    return product_mode(caps)


if __name__ == "__main__":
    raise SystemExit(main())
