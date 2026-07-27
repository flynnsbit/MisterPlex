#!/usr/bin/env python3
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RTL_LINT = ROOT / "scripts" / "rtl_lint.py"

spec = importlib.util.spec_from_file_location("rtl_lint", RTL_LINT)
rtl_lint = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(rtl_lint)


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(f"FAIL quartus subset lint: {msg}")


bad = """
module bad_writeback #(
    parameter int MB_COUNT = 1170,
    localparam int MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT)
) (
    input wire clk
);
endmodule
"""
issues = rtl_lint.check_quartus_subset_text("bad.sv", bad)
require(issues and "localparam in a module parameter port list" in issues[0],
        "localparam parameter-list red-check did not fail")

good = """
module good_writeback #(
    parameter int MB_COUNT = 1170,
    parameter int MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT)
) (
    input wire clk
);
    localparam int INNER = MB_AW;
endmodule
"""
require(not rtl_lint.check_quartus_subset_text("good.sv", good),
        "legal parameter-list rewrite or body localparam was rejected")

print("PASS quartus subset lint: localparam parameter-list red-check fails and rewrite passes")
