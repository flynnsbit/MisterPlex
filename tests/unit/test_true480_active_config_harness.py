#!/usr/bin/env python3
"""Prevent true-480 product simulations from silently compiling macro-off."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
I420_SCRIPT = (ROOT / "tests/unit/test_true480_i420_rtl_sim.sh").read_text()
SHARED_SCRIPT = (ROOT / "tests/unit/test_true480_shared_ddr_rtl_sim.sh").read_text()
I420_TOP = (ROOT / "tests/rtl/true480_i420_tb_top.sv").read_text()
PRESENT_TOP = (ROOT / "tests/rtl/true480_present_tb_top.sv").read_text()
SHARED_TOP = (ROOT / "tests/rtl/true480_shared_ddr_tb_top.sv").read_text()
I420_CPP = (ROOT / "tests/rtl/true480_i420_tb.cpp").read_text()
PRESENT_CPP = (ROOT / "tests/rtl/true480_present_tb.cpp").read_text()
SHARED_CPP = (ROOT / "tests/rtl/true480_shared_ddr_tb.cpp").read_text()
MAKE = (ROOT / "Makefile").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL true480 active-config static: {message}")


for name, script in (
    ("I420", I420_SCRIPT),
    ("shared", SHARED_SCRIPT),
):
    require('if [[ "$MODE" == "--active-gate" ]]' in script,
            f"{name} script lacks an explicit active-gate mode")
    require("+define+PLEX_PRESENT_TRUE_480P" in script,
            f"{name} active mode does not enable the product macro")
    require("present_beam_true_480p.sv" in script,
            f"{name} active file list does not require the native beam")
    require("parameter int Y_FILL_STRIDE = 1" in script,
            f"{name} active mode does not reject a legacy store interface")
    require("--require-active-config" in script,
            f"{name} binary does not verify its elaborated configuration")
    require("refusing macro-OFF" in script,
            f"{name} can silently gate active-capable RTL macro-off")

require('PRESENT_EXTRA_SOURCES=("$RTL/present_beam_true_480p.sv")' in I420_SCRIPT,
        "present build does not conditionally compile the native beam source")
require('ACTIVE_EXTRA_SOURCES=("$RTL/present_beam_true_480p.sv")' in SHARED_SCRIPT,
        "shared active build does not compile the native beam it instantiates")

for name, top in (("I420", I420_TOP), ("shared", SHARED_TOP)):
    require("`ifdef PLEX_PRESENT_TRUE_480P" in top,
            f"{name} top has no product-define branch")
    require(".Y_FILL_STRIDE(1)" in top,
            f"{name} top does not explicitly bind stride 1")
    require("cfg_active_config" in top and "cfg_y_fill_stride" in top,
            f"{name} top lacks runtime configuration markers")

require(".FRAME_Y_FILL_STRIDE(1)" in PRESENT_TOP,
        "present wrapper does not explicitly bind frame fill stride 1")
require("cfg_native_beam_source" in PRESENT_TOP,
        "present wrapper lacks native-beam configuration marker")
require("present_beam_true_480p native_beam" in SHARED_TOP,
        "shared active wrapper does not use the product native beam")
require("parameter int STALE_DOORBELL_FALLBACK_POLLS = 4096" in SHARED_TOP and
        "cfg_stale_doorbell_fallback_polls" in SHARED_TOP,
        "shared active wrapper does not expose the product fallback")
require("kProductStaleDoorbellFallbackPolls = 4096" in SHARED_CPP,
        "shared executable does not enforce the product fallback")
require("parameter int STALE_DOORBELL_FALLBACK_POLLS = 4096" in I420_TOP and
        ".STALE_DOORBELL_FALLBACK_POLLS(STALE_DOORBELL_FALLBACK_POLLS)" in I420_TOP and
        "cfg_stale_doorbell_fallback_polls" in I420_TOP,
        "active I420 wrapper does not expose one explicit fallback parameter")
require("-GSTALE_DOORBELL_FALLBACK_POLLS=\"$PRODUCT_FALLBACK_POLLS\"" in
        I420_SCRIPT and "PRODUCT_FALLBACK_POLLS=4096" in I420_SCRIPT,
        "active I420 build does not bind the product fallback")

for name, cpp in (
    ("I420", I420_CPP),
    ("present", PRESENT_CPP),
    ("shared", SHARED_CPP),
):
    require("--require-active-config" in cpp,
            f"{name} executable does not accept the active assertion")
    require("active configuration disappeared" in cpp,
            f"{name} executable lacks a clear macro-off failure")

require("snapshot calibration must remain" in PRESENT_CPP,
        "snapshot calibration can accidentally inherit the active macro")
require("test_true480_active_config_harness.py" in MAKE,
        "active configuration static guard is not registered in make unit")

print("PASS true480 active-config static: product macro + native beam + "
      "Y_FILL_STRIDE=1 are compile-time and runtime guarded")
