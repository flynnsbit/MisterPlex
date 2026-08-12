#!/usr/bin/env python3
"""Static contract for active shared-gate refill telemetry."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOP = (ROOT / "tests/rtl/true480_shared_ddr_tb_top.sv").read_text()
CPP = (ROOT / "tests/rtl/true480_shared_ddr_tb.cpp").read_text()
MAKE = (ROOT / "Makefile").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL true480 refill telemetry static: {message}")


for signal in (
    "telem_fill_issue",
    "telem_fill_complete",
    "telem_fill_chroma",
    "telem_fill_bank",
    "telem_fill_line",
    "telem_issue_resident",
    "telem_issue_any_resident",
    "telem_issue_needed_current",
    "telem_issue_needed_pending",
    "telem_issue_need_combo",
    "telem_issue_sched_replay",
):
    require(signal in TOP, f"missing testbench observation {signal}")

require("store.state_ddr" in TOP and "store.fill_y" in TOP and
        "store.fill_cy" in TOP,
        "telemetry does not observe real fill state/IDs")
require("store.y_valid" in TOP and "store.c_valid" in TOP,
        "resident-duplicate check does not inspect live tags")
require("store.desired_y_r" in TOP and "store.need_y_cur_c" in TOP,
        "needed/replay classification lacks scheduler demand visibility")

for classification in (
    "STALE_PIPELINE_REPLAY",
    "LEGIT_SLIDING_RELOAD",
    "SAME_WINDOW_RELOAD",
    "INFLIGHT_DUP",
    "NOT_NEEDED",
):
    require(classification in CPP, f"missing class {classification}")

require("TRUE480_REFILL_TELEMETRY" in CPP,
        "quantitative refill summary is not emitted")
require("TRUE480_REFILL_TOP" in CPP and "TRUE480_REFILL_EVENT" in CPP,
        "line-ID records/top offenders are not emitted")
require("detailCoverage" in CPP and "unique_payload_beats=" in CPP,
        "unique Y/C line payload accounting is missing")
require("expected=480/240/56160" in CPP,
        "exact unique m0 payload contract is missing")
require("cfg_refill_telemetry" in TOP and "refill_telemetry=" in CPP,
        "active gate cannot assert telemetry elaboration")
require("test_true480_refill_telemetry_harness.py" in MAKE,
        "refill telemetry static guard is not registered")

print("PASS true480 refill telemetry static: issue/completion IDs + "
      "resident/inflight/not-needed + stale-vs-sliding classes")
