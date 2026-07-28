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


def main() -> int:
    if not TARGET.is_file():
        print(f"mutation target missing: {TARGET}", file=sys.stderr)
        return 1
    text = TARGET.read_text()
    if ANCHOR not in text:
        print(f"mutation anchor missing in {TARGET}: {ANCHOR!r}", file=sys.stderr)
        return 1
    if "dl_probe_dead" in text:
        print("mutation already applied -- refusing to stack it", file=sys.stderr)
        return 1
    TARGET.write_text(text.replace(ANCHOR, INJECT, 1) + APPEND)
    return 0


if __name__ == "__main__":
    sys.exit(main())
