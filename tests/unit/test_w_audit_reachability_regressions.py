#!/usr/bin/env python3
"""Permanent regression cases for the four w-audit reachability-gate attacks.

w-audit (gpt-5.5) broke the core-subtree instrument on 2026-07-28, measured on
w-deblock-seam 7225e00 and recorded in docs/w-audit-core-subtree-gate-attack.md.
Four defects, two of which were *false green* and one *false red*:

1. dead root      -- `--root h264_decode_core` passed while the core had no path
                     to `emu` at all;
2. disabled generate -- `if (0) begin h264_inter_mc_part u_false(); end` made the
                     module report reachable;
3. escaped instance  -- `h264_inter_mc_part \\w_audit.escaped_inst ();` is legal
                     SystemVerilog and reported *un*reachable;
4. files.qip omission -- a tracked, instantiated .sv absent from the Quartus file
                     list reported reachable, i.e. present in the graph and
                     absent from the bitstream.

w-audit also broke a sibling .qip gate with a commented-out assignment, so that
case is covered here too.

Each case runs against the real parser on synthetic sources, so a future refactor
that reintroduces the blind spot fails here rather than in a fit.
"""
from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_rtl_module_instantiations as rtl  # noqa: E402

SCRATCH = ROOT / "build" / "w-audit-regression"


def graph_of(text: str) -> dict[str, set[str]]:
    """Parse SV text exactly as the product gate does, then build the graph."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    path = SCRATCH / "case.sv"
    path.write_text(text)
    modules = rtl.parse_modules([path])
    return modules, rtl.instantiation_graph(modules)


CHILD = "module victim_child (input wire clk); endmodule\n"


def case_disabled_generate() -> None:
    text = CHILD + """
module holder (input wire clk);
generate if (0) begin : g_dead
    victim_child u_false (.clk(clk));
end endgenerate
endmodule
"""
    _mods, graph = graph_of(text)
    assert "victim_child" not in graph["holder"], (
        "an if (0) generate body is elaborated away by Quartus and must not "
        f"create reachability: {graph['holder']}"
    )

    # Control: the identical instantiation outside the disabled block is real.
    live = CHILD + """
module holder (input wire clk);
    victim_child u_real (.clk(clk));
endmodule
"""
    _mods, graph = graph_of(live)
    assert "victim_child" in graph["holder"], graph["holder"]

    # if (1) keeps its body; the else branch is dropped.
    kept = CHILD + """
module holder (input wire clk);
generate if (1) begin : g_live
    victim_child u_real (.clk(clk));
end else begin : g_dead
    other_child u_dead (.clk(clk));
end endgenerate
endmodule
module other_child (input wire clk); endmodule
"""
    _mods, graph = graph_of(kept)
    assert "victim_child" in graph["holder"], graph["holder"]
    assert "other_child" not in graph["holder"], graph["holder"]

    # A non-literal condition must be left alone, i.e. reported reachable.
    param = CHILD + """
module holder #(parameter EN = 0) (input wire clk);
generate if (EN) begin : g_param
    victim_child u_param (.clk(clk));
end endgenerate
endmodule
"""
    _mods, graph = graph_of(param)
    assert "victim_child" in graph["holder"], (
        "parameter conditions are not elaborated; the parser must stay biased "
        "toward reachable rather than silently dropping a live instance"
    )


def case_escaped_instance() -> None:
    text = CHILD + """
module holder (input wire clk);
    victim_child \\w_audit.escaped_inst (.clk(clk));
endmodule
"""
    _mods, graph = graph_of(text)
    assert "victim_child" in graph["holder"], (
        "an escaped instance name is legal SystemVerilog and must not be read as "
        f"absence: {graph['holder']}"
    )


def case_dead_root() -> None:
    """A subtree proof without a trunk proof must not pass."""
    graph = {
        "emu": {"stream_path"},
        "stream_path": {"decode_stub"},
        "decode_stub": set(),
        "orphan_core": {"writeback"},
        "writeback": set(),
    }
    modules = {n: None for n in graph}
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rtl.check_required_modules(
                ["writeback"], "orphan_core", graph, modules, {"stream_path", "decode_stub"}, False
            )
    except SystemExit as exc:
        rc = int(exc.code or 0)
    assert rc == 1, "w-audit case 1: a dead root must not yield a green requirement"
    assert "NON_PRODUCT_ROOT orphan_core" in err.getvalue(), err.getvalue()


def case_trunk_through_masking_lineage() -> None:
    """A trunk that only exists through decode_stub is not a product path."""
    graph = {
        "emu": {"stream_path"},
        "stream_path": {"decode_stub"},
        "decode_stub": {"mc"},
        "mc": {"clamp"},
        "clamp": set(),
    }
    modules = {n: None for n in graph}
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rtl.check_required_modules(
                ["clamp"], "mc", graph, modules, {"stream_path", "decode_stub", "mc", "clamp"}, False
            )
    except SystemExit as exc:
        rc = int(exc.code or 0)
    assert "TRUNK_PROOF mc path=emu->stream_path->decode_stub->mc" in out.getvalue(), out.getvalue()
    assert rc == 1, "a product path laundered through the retired painter must fail"
    assert "masking lineage" in err.getvalue(), err.getvalue()


def case_trunk_nested_under_masking_lineage() -> None:
    """The stub ancestor must be found at any depth, not only as a direct parent.

    w-audit's later attack on the sibling post-fit tool (docs/
    w-audit-prefit-elaboration-attack.md) showed `--forbid-only-under decode_stub`
    catching direct children only, so a grandchild of the retired painter went
    green. The same blind spot must not exist here: the trunk walk inspects the
    whole path, so a module four hops below the stub is still laundered.
    """
    graph = {
        "emu": {"stream_path"},
        "stream_path": {"decode_stub"},
        "decode_stub": {"one_ref"},
        "one_ref": {"mb_write_addr"},
        "mb_write_addr": {"i420_addr"},
        "i420_addr": {"leaf"},
        "leaf": set(),
    }
    modules = {n: None for n in graph}
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rtl.check_required_modules(["leaf"], "i420_addr", graph, modules, set(graph), False)
    except SystemExit as exc:
        rc = int(exc.code or 0)
    assert "via_masking_lineage=decode_stub" in out.getvalue(), out.getvalue()
    assert rc == 1, "a nested descendant of the retired painter must fail the trunk proof"
    assert "masking lineage" in err.getvalue(), err.getvalue()


def case_parametric_generate_undecidable() -> None:
    """w-audit finding 3: a parameter-gated generate is real elaboration, not regex.

    The parser deliberately does NOT guess parameter values -- guessing would let
    it invent absence. Instead the module is declared *undecidable*: reported in
    the inventory and hard-failed if it is asked to back a --require claim, so it
    must be proved by make post-fit-hierarchy instead of by this graph.
    """
    text = """
module disabled_child(input logic a, output logic b); assign b = ~a; endmodule
module live_child(input logic a, output logic b); assign b = a; endmodule
module gen_parent #(parameter bit USE_DISABLED = 1'b0)(input logic a, output logic b);
  generate
    if (USE_DISABLED) begin : g_bad
      disabled_child u_bad(.a(a), .b(b));
    end else begin : g_good
      live_child u_good(.a(a), .b(b));
    end
  endgenerate
endmodule
module emu(input logic a, output logic b); gen_parent #(.USE_DISABLED(1'b0)) u(.a(a), .b(b)); endmodule
"""
    modules, graph = graph_of(text)
    assert "disabled_child" in graph["gen_parent"], (
        "the graph must stay biased to reachable; the parser may not invent absence"
    )
    undecidable = rtl.unresolved_generate_sites(modules)
    assert "disabled_child" in undecidable, (
        "a module reachable only through an unevaluable generate condition must be "
        f"declared undecidable, not silently green: {sorted(undecidable)}"
    )
    assert "live_child" not in undecidable, (
        "the else-branch is not gated by an unevaluable condition; flagging it would "
        f"make the inventory noise: {sorted(undecidable)}"
    )
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rtl.check_required_modules(
                ["disabled_child"], "emu", graph, modules, set(graph), False
            )
    except SystemExit as exc:
        rc = int(exc.code or 0)
    assert rc == 1, "an undecidable module must not back a product --require claim"
    assert "REQUIRED_RTL_MODULE_UNDECIDABLE disabled_child" in err.getvalue(), err.getvalue()
    # rc==1 alone is vacuous here: the synthetic file is in no .qip, so that check
    # would fail it anyway. Assert the *undecidability* verdict specifically.
    assert "must be proved by make post-fit-hierarchy" in err.getvalue(), err.getvalue()


def case_qip_comment_and_path() -> None:
    """A commented assignment compiles nothing; a same-basename path is not a match.

    Drives the *product* helper `rtl.qip_sources_from_text` rather than a local
    copy of it, so a regression in the shipped parser fails here.
    """
    qip_dir = SCRATCH / "qipcase"
    qip_dir.mkdir(parents=True, exist_ok=True)
    body = (
        "set_global_assignment -name SYSTEMVERILOG_FILE rtl/live.sv\n"
        "# set_global_assignment -name SYSTEMVERILOG_FILE rtl/commented.sv\n"
        "set_global_assignment -name SYSTEMVERILOG_FILE rtl_old/moved.sv\n"
        "   # trailing comment set_global_assignment -name SYSTEMVERILOG_FILE rtl/tricky.sv\n"
    )
    (qip_dir / "files.qip").write_text(body)
    resolved = rtl.qip_sources_from_text(body, qip_dir)
    names = {p.name for p in resolved}
    assert "live.sv" in names, names
    assert "commented.sv" not in names, "a commented assignment must not count as coverage"
    assert "tricky.sv" not in names, "a trailing comment must not count as coverage"
    moved = qip_dir / "rtl_old" / "moved.sv"
    assert moved.resolve() in resolved, "paths resolve relative to the .qip directory"
    assert (qip_dir / "rtl" / "moved.sv").resolve() not in resolved, (
        "matching on basename would call rtl/moved.sv compiled when the .qip names "
        "rtl_old/moved.sv"
    )


def main() -> int:
    cases = [
        case_disabled_generate,
        case_escaped_instance,
        case_dead_root,
        case_trunk_through_masking_lineage,
        case_trunk_nested_under_masking_lineage,
        case_parametric_generate_undecidable,
        case_qip_comment_and_path,
    ]
    print(f"Scope: w_audit_regression_cases={len(cases)} attacked_gate=check_rtl_module_instantiations.py", flush=True)
    assert cases, "Scope: 0 cannot claim a PASS"
    for case in cases:
        case()
    print(f"W_AUDIT_REGRESSION_OK cases={len(cases)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
