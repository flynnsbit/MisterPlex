#!/usr/bin/env python3
"""Static contract for the fit-blocking true-480 shared-DDR proof."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
TOP = (ROOT / "tests/rtl/true480_shared_ddr_tb_top.sv").read_text()
CPP = (ROOT / "tests/rtl/true480_shared_ddr_tb.cpp").read_text()
SCRIPT = (ROOT / "tests/unit/test_true480_shared_ddr_rtl_sim.sh").read_text()
PRESENT_CPP = (ROOT / "tests/rtl/true480_present_tb.cpp").read_text()
PRESENT_SCRIPT = (ROOT / "tests/unit/test_true480_i420_rtl_sim.sh").read_text()
MAKE = (ROOT / "Makefile").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL true480 shared harness static: {message}")


for binding in (
    "ddr_frame_store #(",
    "ddr_bus_arbiter arb",
    ".m0_rd(m0_rd)",
    ".m1_rd(m1_rd)",
    ".m1_want(m1_want)",
    ".LINE_COUNT(LINE_COUNT)",
    "beam_x_r == 10'd671",
    "beam_y_r == 9'd495",
):
    require(binding in TOP, f"missing real shared-path binding {binding}")

for hook in (
    "obs_y_hit",
    "obs_c_hit",
    "obs_miss",
    "obs_src_x_now",
    "obs_src_y_now",
):
    require(hook in TOP, f"missing explicit store observation {hook}")

require("M1_ISSUE" in TOP and "m1_rd <= 1'b1" in TOP,
        "m1 command must be held across synchronized busy/refresh races")
require("baseLatency = 24" in CPP and "latencyJitter = 32" in CPP,
        "missing nonzero variable DDR latency")
require("refreshPeriod = 702" in CPP and "refreshStallCycles" in CPP,
        "missing periodic refresh stalls")
require("beatGapPeriod = 17" in CPP and "burstGapCycles" in CPP,
        "missing within-burst controller stalls")
require("m1_beat_conservation" in CPP and
        "physical_burst_conservation" in CPP,
        "missing STREAM/full-burst response conservation gates")
for contract in (
    "kExactUniqueM0Payload == 56160",
    "kPhaseTolerantM0Floor = 54912",
    "kM0PayloadCeiling = 70000",
    "kHarnessSharedPayloadCeiling = 100000",
    "shared_ceiling_scope=HARNESS_ONLY",
    "kCalibratedM1ReadsMin = 20000",
    "kCalibratedM1ReadsMax = 30000",
    "kCalibratedM1WantMin = 400000",
    "kCalibratedM1WantMax = 520000",
    "kCleanReferenceM1Reads = 25674",
    "kCleanReferenceM1WantCycles = 435552",
    "m1_band=CALIBRATED_CLEAN_31EE409D",
    "kExactLinebufBits = 159744",
    "kExactM10Ks = 96",
    "lc8_contract=EXACT",
):
    require(contract in CPP, f"missing calibrated bandwidth contract {contract}")
require("m0Beats < 50000" not in CPP and "m1Reads < 10000" not in CPP,
        "obsolete false-green bandwidth floors remain")
require("PROVISIONAL_UNTIL_FIRST_CLEAN" not in CPP,
        "m1 bands were not frozen after the first clean active run")
require("m.softC != 0" in CPP and "m.underrunAfter != m.underrunBefore" in CPP,
        "missing soft-C and steady-underrun gates")
require("m.rows.size() != 480" in CPP and "m.visibleXs.size() != 618" in CPP,
        "missing exact 480-row/618-column geometry gate")
require("159744" in CPP and "M10K_budget" in CPP,
        "missing stride-1 LINE_COUNT=8 M10K contract")
require("settled_unique_m0_issues" in CPP and
        "settled_unique_m0_completions" in CPP and
        "settled_refill_window" in CPP,
        "unique payload is not tied to a settled issue/completion window")

for red_twin in (
    "idealized_DDR",
    "insufficient_line_depth",
    "excessive_M10K_budget",
):
    require(red_twin in SCRIPT, f"missing shared red twin {red_twin}")

for calibration in ("--calibrate-keepv22", "--calibrate-keepv27"):
    require(calibration in PRESENT_CPP and calibration in PRESENT_SCRIPT,
            f"missing unchanged snapshot calibration {calibration}")
require("NEUTRAL_GRAY_C_STARVATION" in PRESENT_CPP,
        "keepv22 calibration lacks gray/C-starvation signature")
require("BLACK_NO_SWAP" in PRESENT_CPP,
        "keepv27 calibration lacks black/no-swap signature")
require(re.search(r"^true480-shared-ddr:", MAKE, re.MULTILINE) is not None,
        "Makefile target true480-shared-ddr is not registered")

print("PASS true480 shared harness static: real arbiter + periodic STREAM + "
      "latency/burst/refresh stalls + bandwidth/M10K + snapshot calibrations")
