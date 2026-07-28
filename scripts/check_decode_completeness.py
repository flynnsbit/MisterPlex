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
import rtl_sink_analysis as sinkan  # noqa: E402

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
REQUIRED_PRODUCT_DECODER = "h264_decode_core"
RETIRED_PRODUCT_DECODERS = ("decode_stub",)
SUBENGINE_ONLY_DECODERS = ("h264_decode_top",)
PRODUCT_DECODER_PARENT = "stream_path"
# Outputs the product decoder must actually drive.  A decoder whose reconstructed
# samples never reach the frame store writes no pixels, so structural
# instantiation of it proves nothing about the shipped bitstream.
REQUIRED_LIVE_OUTPUT_PORTS = ("dpb_wr_en", "dpb_wr_addr", "dpb_wr_data")


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


def check_capabilities(
    label: str,
    scope_reachable: set[str],
    caps: dict[str, Capability],
    *,
    scope_name: str = "product_decoder_subtree",
    wider_reachable: set[str] | None = None,
) -> tuple[bool, list[str]]:
    """Every category must be satisfied *inside* ``scope_reachable``.

    ``wider_reachable`` is only used for diagnostics: a module that is missing
    from the product decoder subtree but present elsewhere in the product graph
    is being donated by a non-product lineage (typically the retired stub).  That
    is the exact shape of a capability gate that reads true about the wrong
    subtree, so it is reported explicitly and still counted as missing.
    """
    wider = wider_reachable if wider_reachable is not None else set()
    missing_categories: list[str] = []
    for category in REQUIRED_CATEGORIES:
        cap = caps[category]
        present = [module for module in cap.modules if module in scope_reachable]
        missing = [module for module in cap.modules if module not in scope_reachable]
        donated = [module for module in missing if module in wider]
        status = "PASS" if not missing else "FAIL"
        if missing:
            missing_categories.append(category)
        print(
            f"DECODE_CAPABILITY config={label} scope={scope_name} category={category} status={status} "
            f"present={','.join(present) if present else '<none>'} "
            f"missing={','.join(missing) if missing else '<none>'} "
            f"donated_by_non_product_lineage={','.join(donated) if donated else '<none>'}"
        )
    return not missing_categories, missing_categories


def check_output_sinks(
    label: str,
    parent_body: str | None,
    child_body: str | None,
    *,
    decoder: str = REQUIRED_PRODUCT_DECODER,
    parent: str = PRODUCT_DECODER_PARENT,
) -> bool:
    """The product decoder's outputs must reach something other than an anti-prune net.

    Reachability gates answer "is it instantiated".  They cannot answer "does
    anything consume what it produces".  A decoder whose entire output cone
    terminates on a dangling ``wire _keep = a | b | c;`` is instantiated in
    source, pruned by synthesis, and absent from the bitstream.
    """
    if parent_body is None or child_body is None:
        print(
            f"DECODE_OUTPUT_SINK config={label} decoder={decoder} parent={parent} status=FAIL "
            "outputs=0 live=0 dead_end=0 unconnected=0 problems=decoder_or_parent_module_missing"
        )
        return False
    sinks, declared_outputs = sinkan.analyze_output_sinks(parent_body, child_body, decoder)
    if not sinks:
        print(
            f"DECODE_OUTPUT_SINK config={label} decoder={decoder} parent={parent} status=FAIL "
            f"outputs=0 declared_outputs={len(declared_outputs)} live=0 dead_end=0 unconnected=0 "
            "problems=product_decoder_not_instantiated_in_parent"
        )
        return False
    live = [s for s in sinks if s.status == "live"]
    dead = [s for s in sinks if s.status == "dead_end"]
    unconnected = [s for s in sinks if s.status == "unconnected"]
    problems: list[str] = []
    if not live:
        problems.append("all_outputs_dead_end")
    by_port = {s.port: s for s in sinks}
    for port in REQUIRED_LIVE_OUTPUT_PORTS:
        s = by_port.get(port)
        if s is None:
            problems.append(f"required_output_absent={port}")
        elif s.status != "live":
            problems.append(f"required_output_not_live={port}:{s.status}")
    status = "PASS" if not problems else "FAIL"
    print(
        f"DECODE_OUTPUT_SINK config={label} decoder={decoder} parent={parent} status={status} "
        f"outputs={len(sinks)} declared_outputs={len(declared_outputs)} live={len(live)} "
        f"dead_end={len(dead)} unconnected={len(unconnected)} "
        f"dead_end_ports={','.join(s.port for s in dead) if dead else '<none>'} "
        f"terminal_nets={','.join(sorted({t for s in dead for t in s.detail.split(',')})) if dead else '<none>'} "
        f"problems={','.join(problems) if problems else '<none>'}"
    )
    return not problems


def check_topology(
    label: str,
    graph: dict[str, set[str]],
    reachable: set[str],
    *,
    stream_module: str = "stream_path",
) -> bool:
    direct_decode_children = sorted(graph.get(stream_module, set()) & set(LINEAGE_ROOTS))
    core_descendants = descendants(REQUIRED_PRODUCT_DECODER, graph)
    problems: list[str] = []

    if REQUIRED_PRODUCT_DECODER not in reachable:
        problems.append(f"missing_product_decoder={REQUIRED_PRODUCT_DECODER}")
    if REQUIRED_PRODUCT_DECODER not in direct_decode_children:
        problems.append(f"stream_path_not_instantiating={REQUIRED_PRODUCT_DECODER}")

    for retired in RETIRED_PRODUCT_DECODERS:
        if retired in reachable:
            problems.append(f"retired_decoder_reachable={retired}")
        if retired in direct_decode_children:
            problems.append(f"retired_decoder_direct_child={retired}")

    for subengine in SUBENGINE_ONLY_DECODERS:
        if subengine in direct_decode_children:
            problems.append(f"subengine_used_as_product_decoder={subengine}")
        if subengine in reachable and subengine not in core_descendants:
            problems.append(f"subengine_reachable_outside_core={subengine}")

    if "h264_decode_skeleton" in reachable:
        problems.append("resource_skeleton_product_reachable=h264_decode_skeleton")

    status = "PASS" if not problems else "FAIL"
    print(
        f"DECODE_TOPOLOGY config={label} status={status} "
        f"direct_stream_path_decoders={','.join(direct_decode_children) if direct_decode_children else '<none>'} "
        f"required_product_decoder={REQUIRED_PRODUCT_DECODER} "
        f"subengine_only={','.join(SUBENGINE_ONLY_DECODERS)} "
        f"retired={','.join(RETIRED_PRODUCT_DECODERS)} "
        f"problems={','.join(problems) if problems else '<none>'}"
    )
    return not problems


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
        cfg_modules, graph, reachable = rtl.build_reachable(paths, overrides)
        rtl_reachable = reachable & rtl_modules
        product_roots = {root for root in LINEAGE_ROOTS if root in rtl_reachable}
        product_roots_by_config[label] = product_roots
        topology_ok = check_topology(label, graph, rtl_reachable)
        parent_mod = cfg_modules.get(PRODUCT_DECODER_PARENT)
        child_mod = cfg_modules.get(REQUIRED_PRODUCT_DECODER)
        sinks_ok = check_output_sinks(
            label,
            parent_mod.body if parent_mod else None,
            child_mod.body if child_mod else None,
        )
        core_subtree: set[str] = set()
        if REQUIRED_PRODUCT_DECODER in rtl_reachable:
            core_subtree = descendants(REQUIRED_PRODUCT_DECODER, graph) & rtl_modules & rtl_reachable
        print(
            f"DECODE_PRODUCT_SUBTREE config={label} root={REQUIRED_PRODUCT_DECODER} "
            f"modules={len(core_subtree)} product_reachable={len(rtl_reachable)} "
            f"outside_core={len(rtl_reachable - core_subtree)}"
        )
        ok, missing_categories = check_capabilities(
            label, core_subtree, caps, wider_reachable=rtl_reachable
        )
        all_ok = all_ok and topology_ok and sinks_ok and ok
        print(
            f"DECODE_COMPLETENESS_CONFIG config={label} status={'PASS' if (topology_ok and sinks_ok and ok) else 'FAIL'} "
            f"reachable={len(rtl_reachable)} core_subtree={len(core_subtree)} "
            f"decode_roots={','.join(sorted(product_roots)) if product_roots else '<none>'} "
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


SYNTH_CHILD_LIVE = """
module h264_decode_core #(parameter FRAME_W = 640) (
    input  wire clk,
    input  wire reset,
    output wire dpb_wr_en,
    output wire [31:0] dpb_wr_addr,
    output wire [7:0] dpb_wr_data,
    output wire frame_done
);
endmodule
"""

SYNTH_PARENT_LIVE = """
module stream_path (
    input  wire clk,
    input  wire reset,
    output wire fs_wr_en,
    output wire [31:0] fs_wr_addr,
    output wire [7:0] fs_wr_data,
    output wire fs_frame_done
);
    wire core_dpb_wr_en;
    wire [31:0] core_dpb_wr_addr;
    wire [7:0] core_dpb_wr_data;
    wire core_frame_done;
    h264_decode_core #(.FRAME_W(640)) product_decode_core (
        .clk(clk), .reset(reset),
        .dpb_wr_en(core_dpb_wr_en),
        .dpb_wr_addr(core_dpb_wr_addr),
        .dpb_wr_data(core_dpb_wr_data),
        .frame_done(core_frame_done)
    );
    assign fs_wr_en = core_dpb_wr_en;
    assign fs_wr_addr = core_dpb_wr_addr;
    assign fs_wr_data = core_dpb_wr_data;
    assign fs_frame_done = core_frame_done;
endmodule
"""

SYNTH_PARENT_DEAD = """
module stream_path (
    input  wire clk,
    input  wire reset,
    output wire fs_wr_en,
    output wire [31:0] fs_wr_addr,
    output wire [7:0] fs_wr_data,
    output wire fs_frame_done
);
    wire core_dpb_wr_en;
    wire [31:0] core_dpb_wr_addr;
    wire [7:0] core_dpb_wr_data;
    wire core_frame_done;
    h264_decode_core #(.FRAME_W(640)) product_decode_core (
        .clk(clk), .reset(reset),
        .dpb_wr_en(core_dpb_wr_en),
        .dpb_wr_addr(core_dpb_wr_addr),
        .dpb_wr_data(core_dpb_wr_data),
        .frame_done(core_frame_done)
    );
    assign fs_wr_en = 1'b0;
    assign fs_wr_addr = 32'd0;
    assign fs_wr_data = 8'd0;
    assign fs_frame_done = 1'b0;
    wire _keep = core_dpb_wr_en | |core_dpb_wr_addr | |core_dpb_wr_data | core_frame_done;
endmodule
"""


def synthetic_mode(
    caps: dict[str, Capability],
    drop_category: str | None,
    bad_topology: bool,
    dead_outputs: bool,
) -> int:
    if drop_category and drop_category not in caps:
        fail(f"unknown synthetic drop category {drop_category!r}")
    print(
        "Scope: decode-completeness synthetic "
        f"required_categories={len(REQUIRED_CATEGORIES)} drop_category={drop_category or '<none>'} "
        f"bad_topology={int(bad_topology)} dead_outputs={int(dead_outputs)}"
    )
    if bad_topology:
        graph = {
            "emu": {"stream_path"},
            "stream_path": {"decode_stub"},
            "decode_stub": set(),
            "h264_decode_core": {"h264_decode_top"},
            "h264_decode_top": set(),
        }
    else:
        graph = {
            "emu": {"stream_path"},
            "stream_path": {"h264_decode_core"},
            "h264_decode_core": {"h264_decode_top"},
            "h264_decode_top": set(),
            "decode_stub": set(),
        }
    reachable = descendants("emu", graph)
    for category in REQUIRED_CATEGORIES:
        if category == drop_category:
            continue
        reachable.update(caps[category].modules)
        graph.setdefault(REQUIRED_PRODUCT_DECODER, set()).update(caps[category].modules)
    topology_ok = check_topology("synthetic", graph, reachable)
    parent_body = _synth_body(SYNTH_PARENT_DEAD if dead_outputs else SYNTH_PARENT_LIVE)
    child_body = _synth_body(SYNTH_CHILD_LIVE)
    sinks_ok = check_output_sinks("synthetic", parent_body, child_body)
    core_subtree = descendants(REQUIRED_PRODUCT_DECODER, graph)
    print(
        f"DECODE_PRODUCT_SUBTREE config=synthetic root={REQUIRED_PRODUCT_DECODER} "
        f"modules={len(core_subtree)} product_reachable={len(reachable)} "
        f"outside_core={len(reachable - core_subtree)}"
    )
    ok, missing_categories = check_capabilities(
        "synthetic", core_subtree, caps, wider_reachable=reachable
    )
    print(
        f"DECODE_COMPLETENESS_CONFIG config=synthetic status={'PASS' if (topology_ok and sinks_ok and ok) else 'FAIL'} "
        f"reachable={len(reachable)} core_subtree={len(core_subtree)} "
        f"decode_roots={','.join(sorted(reachable & set(LINEAGE_ROOTS)))} "
        f"missing_categories={','.join(missing_categories) if missing_categories else '<none>'}"
    )
    if topology_ok and sinks_ok and ok:
        print("DECODE_COMPLETENESS_OK synthetic complete graph satisfies every category")
        return 0
    print("DECODE_COMPLETENESS_FAIL synthetic graph missing required categories")
    return 1


def _synth_body(text: str) -> str:
    m = re.search(r"\bmodule\s+[A-Za-z_]\w*\b(?P<body>.*?)\bendmodule\b", text, re.S)
    assert m is not None
    return m.group("body")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--synthetic-complete", action="store_true", help="Check a synthetic graph containing all mapped capability modules")
    ap.add_argument("--synthetic-drop-category", help="With --synthetic-complete, remove one category to prove red")
    ap.add_argument("--synthetic-bad-topology", action="store_true", help="With --synthetic-complete, use retired decode_stub as the product decoder")
    ap.add_argument("--synthetic-dead-outputs", action="store_true", help="With --synthetic-complete, terminate every decoder output on a dangling anti-prune net")
    args = ap.parse_args(argv)
    caps = parse_capabilities()
    if args.synthetic_complete or args.synthetic_drop_category or args.synthetic_bad_topology or args.synthetic_dead_outputs:
        return synthetic_mode(caps, args.synthetic_drop_category, args.synthetic_bad_topology, args.synthetic_dead_outputs)
    return product_mode(caps)


if __name__ == "__main__":
    raise SystemExit(main())
