#!/usr/bin/env python3
"""Unit coverage for output-sink liveness and Quartus compile membership.

Both checks exist because source-graph reachability is silent about two ways a
module can be present in the tree and absent from the bitstream:

* every output terminates on a dangling anti-prune net, so synthesis prunes it;
* its source file is in no tracked .qip, so Quartus never compiles it.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import rtl_sink_analysis as sinkan  # noqa: E402
import check_rtl_module_instantiations as rtl  # noqa: E402

CHILD = """
module child_dec #(parameter W = 8) (
    input  wire clk,
    output wire wr_en,
    output wire [7:0] wr_data,
    output wire done
);
endmodule
"""

PARENT_LIVE = """
module parent_top (
    input  wire clk,
    output wire fs_wr_en,
    output wire [7:0] fs_wr_data
);
    wire c_wr_en;
    wire [7:0] c_wr_data;
    wire c_done;
    child_dec #(.W(8)) u_child (
        .clk(clk), .wr_en(c_wr_en), .wr_data(c_wr_data), .done(c_done)
    );
    assign fs_wr_en = c_wr_en & c_done;
    assign fs_wr_data = c_wr_data;
endmodule
"""

PARENT_DEAD = """
module parent_top (
    input  wire clk,
    output wire fs_wr_en,
    output wire [7:0] fs_wr_data
);
    wire c_wr_en;
    wire [7:0] c_wr_data;
    wire c_done;
    child_dec #(.W(8)) u_child (
        .clk(clk), .wr_en(c_wr_en), .wr_data(c_wr_data), .done(c_done)
    );
    assign fs_wr_en = 1'b0;
    assign fs_wr_data = 8'd0;
    wire _keep = c_wr_en | |c_wr_data | c_done;
endmodule
"""

PARENT_INDIRECT_DEAD = """
module parent_top (
    input  wire clk,
    output wire fs_wr_en,
    output wire [7:0] fs_wr_data
);
    wire c_wr_en;
    wire [7:0] c_wr_data;
    wire c_done;
    child_dec #(.W(8)) u_child (
        .clk(clk), .wr_en(c_wr_en), .wr_data(c_wr_data), .done(c_done)
    );
    assign fs_wr_en = 1'b0;
    assign fs_wr_data = 8'd0;
    wire hop_a = c_wr_en | c_done;
    wire hop_b = hop_a | |c_wr_data;
    wire _keep = hop_b;
endmodule
"""

PARENT_INSTANCE_SINK = """
module parent_top (
    input  wire clk,
    output wire fs_wr_en,
    output wire [7:0] fs_wr_data
);
    wire c_wr_en;
    wire [7:0] c_wr_data;
    wire c_done;
    child_dec #(.W(8)) u_child (
        .clk(clk), .wr_en(c_wr_en), .wr_data(c_wr_data), .done(c_done)
    );
    assign fs_wr_en = 1'b0;
    assign fs_wr_data = 8'd0;
    other_sink u_sink (.clk(clk), .en(c_wr_en), .data(c_wr_data), .done(c_done));
endmodule
"""


PARENT_SLICE_LIVE = """
module parent_top (
    input  wire clk,
    output wire [15:0] fs_bus
);
    wire c_wr_en;
    wire [7:0] c_wr_data;
    wire c_done;
    child_dec #(.W(8)) u_child (
        .clk(clk), .wr_en(c_wr_en), .wr_data(c_wr_data[7:0]), .done(c_done)
    );
    assign fs_bus = {c_wr_data, 6'd0, c_done, c_wr_en};
endmodule
"""

PARENT_GENERATE_DEAD_SECOND = """
module parent_top (
    input  wire clk,
    output wire fs_wr_en,
    output wire [7:0] fs_wr_data
);
    wire c_wr_en;
    wire [7:0] c_wr_data;
    wire c_done;
    wire d_wr_en;
    wire [7:0] d_wr_data;
    wire d_done;
    generate
      begin : gen_decoy
        child_dec #(.W(8)) u_decoy (
            .clk(clk), .wr_en(d_wr_en), .wr_data(d_wr_data), .done(d_done)
        );
      end
      begin : gen_product
        child_dec #(.W(8)) u_child (
            .clk(clk), .wr_en(c_wr_en), .wr_data(c_wr_data), .done(c_done)
        );
      end
    endgenerate
    assign fs_wr_en = d_wr_en;
    assign fs_wr_data = d_wr_data;
    wire _keep = c_wr_en | |c_wr_data | c_done | d_done;
endmodule
"""


def body(text: str) -> str:
    m = re.search(r"\bmodule\s+[A-Za-z_]\w*\b(?P<body>.*?)\bendmodule\b", text, re.S)
    assert m is not None
    return m.group("body")


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def statuses(parent_text: str) -> dict[str, str]:
    sinks, _ = sinkan.analyze_output_sinks(body(parent_text), body(CHILD), "child_dec")
    return {s.port: s.status for s in sinks}


def check_sink_analysis() -> None:
    live = statuses(PARENT_LIVE)
    print(f"Scope: sink-analysis synthetic_parents=6 child_outputs={len(live)}")
    require(len(live) == 3, f"expected 3 connected child outputs, got {live}")
    require(all(v == "live" for v in live.values()), f"real sinks must be live: {live}")
    print("PASS real parent-output sinks classify live")

    dead = statuses(PARENT_DEAD)
    require(all(v == "dead_end" for v in dead.values()), f"anti-prune-only sinks must be dead_end: {dead}")
    print("PASS anti-prune _keep OR-reduction classifies dead_end")

    indirect = statuses(PARENT_INDIRECT_DEAD)
    require(
        all(v == "dead_end" for v in indirect.values()),
        f"multi-hop anti-prune chain must still be dead_end: {indirect}",
    )
    print("PASS multi-hop anti-prune chain classifies dead_end")

    instance = statuses(PARENT_INSTANCE_SINK)
    require(
        all(v == "live" for v in instance.values()),
        f"nets escaping into another instance must be live: {instance}",
    )
    print("PASS nets consumed by another module instance classify live")

    sliced = statuses(PARENT_SLICE_LIVE)
    require(
        all(v == "live" for v in sliced.values()),
        f"part-select and concatenation connections must not be scored unconnected: {sliced}",
    )
    print("PASS part-select/concatenation connections classify live")

    gen = statuses(PARENT_GENERATE_DEAD_SECOND)
    require(
        gen.get("wr_en") == "live" and gen.get("wr_data") == "live" and gen.get("done") == "dead_end",
        f"multi-instance generate blocks must be scored per port across all instances: {gen}",
    )
    print("PASS generate-block duplicate instances are all analysed")


def check_qip_membership() -> None:
    paths = rtl.git_files("fpga/Plex_MiSTer/rtl") + [rtl.PRODUCT_TOP]
    modules, _graph, reachable = rtl.build_reachable(paths)
    compiled = rtl.tracked_qip_sources()
    print(
        f"Scope: qip-membership tracked_qip_sources={len(compiled)} "
        f"product_reachable_modules={len(reachable)}"
    )
    require(len(compiled) > 0, "no tracked .qip source files discovered")
    require(len(reachable) > 0, "no product-reachable modules discovered")
    gaps = rtl.qip_membership_gaps(modules, reachable)
    require(not gaps, f"product-reachable modules missing from the Quartus compile: {gaps}")
    print("PASS every product-reachable module is compiled by a tracked .qip")

    # red: a module that exists on disk but is in no .qip must be reported.
    fake = dict(modules)
    fake["__synthetic_uncompiled__"] = rtl.ModuleDef(
        "__synthetic_uncompiled__", rtl.RTL_DIR / "does_not_exist_in_qip.sv", ""
    )
    red = rtl.qip_membership_gaps(fake, reachable | {"__synthetic_uncompiled__"})
    require(
        [name for name, _ in red] == ["__synthetic_uncompiled__"],
        f"synthetic uncompiled module was not reported: {red}",
    )
    print("PASS a reachable module absent from every .qip is reported red")


def check_gate_wiring() -> None:
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "check_rtl_module_instantiations.py")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=300,
    )
    combined = proc.stdout + proc.stderr
    require(proc.returncode == 0, f"instantiation gate must be green here\n{combined}")
    require("RTL_MODULE_INSTANTIATION_OK" in combined, f"missing OK line\n{combined}")
    print("PASS instantiation gate stays green with the compile-membership check wired in")


def main() -> int:
    check_sink_analysis()
    check_qip_membership()
    check_gate_wiring()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
