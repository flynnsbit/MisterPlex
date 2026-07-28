#!/usr/bin/env python3
"""Mutation helper for tests/unit/test_deadlogic_sink_redproof.sh.

Injects two byte-identical probe modules into the product RTL.  One has its
output routed to a port of the product top; the other's output is read by
nothing.  Since the modules are otherwise identical, the only property
check_deadlogic_sink.py can be discriminating on is observability -- which is
exactly the property Quartus uses when it deletes logic.

Kept as its own file rather than a heredoc inside the shell script: escaping
Verilog tabs and newlines through two levels of quoting silently corrupted the
generated source, and a mutation that fails to apply makes a red proof look
like a tooling problem instead of a result.
"""

from __future__ import annotations

import sys
from pathlib import Path

MODE = sys.argv[1] if len(sys.argv) > 1 else "--observability"

TARGET = Path("fpga/Plex_MiSTer/rtl/stream_path.sv")
ANCHOR = "\tassign has_idr     = has_idr_w;"

INJECT = (
    "\twire [7:0] dl_probe_dead_q;\n"
    "\twire [7:0] dl_probe_live_q;\n"
    "\tdl_probe_dead u_dl_probe_dead (.clk(clk), .q(dl_probe_dead_q));\n"
    "\tdl_probe_live u_dl_probe_live (.clk(clk), .q(dl_probe_live_q));\n"
    "\tassign has_idr     = has_idr_w | (|dl_probe_live_q);\n"
)

APPEND = (
    "\nmodule dl_probe_dead (input wire clk, output wire [7:0] q);\n"
    "\tassign q = {7'd0, clk};\n"
    "endmodule\n"
    "\nmodule dl_probe_live (input wire clk, output wire [7:0] q);\n"
    "\tassign q = {7'd0, clk};\n"
    "endmodule\n"
)


# --constfold: the BLIND SPOT probe.  Its output IS routed to a port of emu,
# so it is observable and check_deadlogic_sink.py reports it LIVE -- but it is
# driven by a pure constant, contributes zero resources, and Quartus therefore
# deletes it exactly as it deletes h264_decode_core.  This is the sub-case of
# failure mode 3 that no observability analysis can reach, and it is not
# hypothetical here: the core's inputs are tied to constants at
# stream_path.sv:447-459, so the core could still collapse by constant
# propagation even after someone consumes its outputs.
CONSTFOLD_INJECT = (
    "\twire [7:0] dl_probe_constfold_q;\n"
    "\tdl_probe_constfold u_dl_probe_constfold (.clk(clk), .q(dl_probe_constfold_q));\n"
    "\tassign has_idr     = has_idr_w | (|dl_probe_constfold_q);\n"
)

CONSTFOLD_APPEND = (
    "\nmodule dl_probe_constfold (input wire clk, output wire [7:0] q);\n"
    "\tassign q = 8'd0;\n"
    "endmodule\n"
)


def verify_twins() -> int:
    """The twin probes must differ ONLY in the independent variable.

    Mechanical, not a matter of remembering. The parent published an
    exoneration built on four builds that all shared the same value of the
    variable under test; the comparison proved determinism and nothing else.
    A twin-probe control has exactly that failure mode: if the two probe bodies
    ever drift apart, red proof 4 could be discriminating on something other
    than observability and would still look like evidence.
    """
    import re as _re

    def body(name: str) -> str | None:
        m = _re.search(
            r"module\s+" + name + r"\b(.*?)endmodule", APPEND, _re.S
        )
        return m.group(1) if m else None

    dead = body("dl_probe_dead")
    live = body("dl_probe_live")
    if dead is None or live is None:
        print("TWIN_CONTROL_VACUOUS: could not extract both probe bodies",
              file=sys.stderr)
        return 1
    if dead != live:
        print("TWIN_CONTROL_VACUOUS: probe bodies differ beyond their names:",
              file=sys.stderr)
        print(f"  dead: {dead!r}", file=sys.stderr)
        print(f"  live: {live!r}", file=sys.stderr)
        return 1
    if "dl_probe_live_q" not in INJECT or "has_idr" not in INJECT:
        print("TWIN_CONTROL_VACUOUS: live probe output is not routed to a port "
              "of the product top, so both twins are unobservable and red proof "
              "4 would be comparing two identical situations", file=sys.stderr)
        return 1
    if "dl_probe_dead_q" in INJECT.split("assign has_idr")[1]:
        print("TWIN_CONTROL_VACUOUS: the dead probe's output reaches the "
              "observable port too -- the twins no longer differ", file=sys.stderr)
        return 1
    print("TWIN_CONTROL_OK probe bodies byte-identical; only observability differs")
    return 0


def main() -> int:
    if MODE == "--verify-twins":
        return verify_twins()
    if not TARGET.is_file():
        print(f"mutation target missing: {TARGET}", file=sys.stderr)
        return 1
    text = TARGET.read_text()
    if ANCHOR not in text:
        print(f"mutation anchor missing in {TARGET}: {ANCHOR!r}", file=sys.stderr)
        return 1
    if "dl_probe_" in text:
        print("mutation already applied -- refusing to stack it", file=sys.stderr)
        return 1
    if MODE == "--constfold":
        TARGET.write_text(text.replace(ANCHOR, CONSTFOLD_INJECT, 1) + CONSTFOLD_APPEND)
        return 0
    if MODE != "--observability":
        print(f"unknown mode: {MODE}", file=sys.stderr)
        return 2
    TARGET.write_text(text.replace(ANCHOR, INJECT, 1) + APPEND)
    return 0


if __name__ == "__main__":
    sys.exit(main())
