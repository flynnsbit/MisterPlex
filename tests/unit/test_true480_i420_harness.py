#!/usr/bin/env python3
"""Static contract for the true-480 I420 red-twin harness."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
TOP = (ROOT / "tests/rtl/true480_i420_tb_top.sv").read_text()
PRESENT = (ROOT / "tests/rtl/true480_present_tb_top.sv").read_text()
CPP = (ROOT / "tests/rtl/true480_i420_tb.cpp").read_text()
SCRIPT = (ROOT / "tests/unit/test_true480_i420_rtl_sim.sh").read_text()
MAKE = (ROOT / "Makefile").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL true480 harness static: {message}")


for literal in (
    ".FRAME_W(640)",
    ".FRAME_H(480)",
    ".CODED_W(624)",
    ".CODED_H(480)",
    ".DISPLAY_W(618)",
    ".DISPLAY_H(480)",
    ".PRESENT_X(PRESENT_X_P)",
):
    require(literal in TOP, f"missing geometry binding {literal}")

for hook in (
    "obs_y_hit",
    "obs_c_hit",
    "obs_y_hit_now",
    "obs_c_hit_now",
    "obs_miss",
    "obs_src_x_now",
    "obs_src_y_now",
):
    require(hook in TOP, f"missing explicit observability hook {hook}")

require("renderIdleYuv420p" in
        (ROOT / "tests/rtl/true480_i420_test_support.hpp").read_text(),
        "fixture does not use the daemon idle I420 renderer")
require("legacy_store_y_2py" in CPP, "missing legacy doubled-row red twin")
require("--scenario c-miss" in SCRIPT, "missing forced C-miss control")
require("--scenario y-miss" in SCRIPT, "missing forced Y-miss control")
require("--scenario bad-bank" in SCRIPT, "missing bad-bank black control")
require("wrong_pillar" in SCRIPT and "wrong_crop" in SCRIPT,
        "missing crop/pillar red twins")
require("present_full_frame_real_rate" in SCRIPT,
        "missing full present_core scan gate")
require("dut.fstore.y_hit_r" in PRESENT and "dut.fstore.c_hit_r" in PRESENT,
        "present wrapper must expose real RTL hits, not infer from RGB")
for hook in (
    "true480_scan_valid",
    "true480_output_x",
    "true480_output_y",
    "true480_store_x",
    "true480_store_y",
    "true480_src_x",
    "true480_src_y",
    "true480_y_hit",
    "true480_c_hit",
    "true480_miss",
    "true480_soft_c_fallback",
):
    require(hook in PRESENT, f"missing explicit future RTL hook contract {hook}")
require(re.search(r"^true480-i420:", MAKE, re.MULTILINE) is not None,
        "Makefile target true480-i420 is not registered")

print("PASS true480 harness static: daemon I420 + explicit Y/C/miss hooks + "
      "legacy/crop/pillar/Y/C/bank red twins + Make target")
