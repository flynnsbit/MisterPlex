#!/usr/bin/env python3
"""Exact-rational audit for the Plex_480i 15 kHz weave beam.

clk_sys stays 20 MHz. Pixel enable is CE 2/3 (pattern 1,1,0). Totals are
849 x 262 per field, 640 x 240 active:

  H     = 40e6 / (3*849)         = 40000000/2547 Hz
  field = 40e6 / (3*849*262)     = 20000000/333657 Hz
  frame = field / 2              = 10000000/333657 Hz

H_SYNC 660..723, V_SYNC 243..246, FIRST_ODD=1, HALFLINE=0, FRAME_LINES=524.

Product Plex.qsf must not enable PLEX_PRESENT_480I (L52 sibling rule).
672x496 @ CE/2 is HDMI true480 ~30.002 Hz, not this 15 kHz weave.

present_beam_480i.sv / Plex_480i.qsf are optional: math + expected-constant
file always run. File-presence is not a skip of the rationals.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QSF_PRODUCT = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
QSF_480I = ROOT / "fpga/Plex_MiSTer/Plex_480i.qsf"
BEAM_SV = ROOT / "fpga/Plex_MiSTer/rtl/present_beam_480i.sv"
CONTRACT_SVH = ROOT / "fpga/Plex_MiSTer/rtl/plex_15k_bw_contract.svh"
EXPECTED_CONST = Path(__file__).resolve().parent / "expected_480i_cadence.txt"
BOB_TEST = Path(__file__).resolve().parent / "test_240p15_cadence.py"
BOB_SV = ROOT / "fpga/Plex_MiSTer/rtl/present_beam_240p15.sv"

SYSTEM_CLOCK_HZ = 20_000_000
CE_NUM = 2
CE_DEN = 3
H_TOTAL_LOCK = 849
V_FIELD = 262
H_DE = 640
V_ACTIVE = 240
H_SYNC_S = 660
H_SYNC_E = 723
V_SYNC_S = 243
V_SYNC_E = 246
FIRST_ODD = 1
HALFLINE = 0
FRAME_LINES = 524

H_HZ_LOCK = Fraction(40_000_000, 2547)
FIELD_HZ_LOCK = Fraction(20_000_000, 333_657)
FRAME_HZ_LOCK = Fraction(10_000_000, 333_657)

# Product HDMI true480 — 20 MHz CE/2, 672x496 → 78125/2604 Hz (~30.0019)
HDMI_CE_DEN = 2
HDMI_H_TOTAL = 672
HDMI_V_TOTAL = 496
HDMI_FRAME_HZ = Fraction(SYSTEM_CLOCK_HZ, HDMI_CE_DEN * HDMI_H_TOTAL * HDMI_V_TOTAL)


def qsf_enables(path: Path, name: str) -> bool:
    needle = f'VERILOG_MACRO "{name}=1"'
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if needle in line:
            return True
    return False


def has_param(src: str, names: tuple[str, ...], value: str) -> bool:
    for name in names:
        if re.search(
            rf"\b{re.escape(name)}\s*=\s*(?:11'd|1'b)?{re.escape(value)}\b",
            src,
        ):
            return True
    return False


def check_math(h_total: int, failures: list[str]) -> None:
    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    check(CE_NUM == 2 and CE_DEN == 3, "CE must be 2/3")
    check(h_total == H_TOTAL_LOCK, "H_TOTAL must be 849")
    check(V_FIELD == 262, "480i weave is a 262-line field")
    check(H_DE == 640 and V_ACTIVE == 240, "active must be 640x240 per field")
    check(H_SYNC_S == 660 and H_SYNC_E == 723, "H_SYNC must be 660..723")
    check(V_SYNC_S == 243 and V_SYNC_E == 246, "V_SYNC must be 243..246")
    check(FIRST_ODD == 1, "FIRST_ODD must be 1 (NTSC odd field first)")
    check(HALFLINE == 0, "HALFLINE must be 0")
    check(FRAME_LINES == 524, "FRAME_LINES must be 524 (2*262, not 525)")
    check(FRAME_LINES == 2 * V_FIELD, "FRAME_LINES must be two 262-line fields")
    check(H_DE + 20 + 63 + 126 == H_TOTAL_LOCK, "H blank 20+63+126 must fill 849")
    check(V_ACTIVE + 3 + 3 + 16 == V_FIELD, "V blank 3+3+16 must fill 262")
    check(H_DE + 20 == H_SYNC_S, "H_SYNC_S must be H_DE+FP")
    check(H_SYNC_S + 63 == H_SYNC_E, "H_SYNC_E must be H_SYNC_S+SW")
    check(V_ACTIVE + 3 == V_SYNC_S, "V_SYNC_S must be V_ACTIVE+FP")
    check(V_SYNC_S + 3 == V_SYNC_E, "V_SYNC_E must be V_SYNC_S+SW")

    h_hz = Fraction(SYSTEM_CLOCK_HZ * CE_NUM, CE_DEN * h_total)
    field_hz = Fraction(SYSTEM_CLOCK_HZ * CE_NUM, CE_DEN * h_total * V_FIELD)
    frame_hz = field_hz / 2

    check(h_hz == H_HZ_LOCK, "H rate must reduce to 40000000/2547")
    check(h_hz == Fraction(40_000_000, 3 * H_TOTAL_LOCK), "H must be 40e6/(3*849)")
    check(field_hz == FIELD_HZ_LOCK, "field rate must reduce to 20000000/333657")
    check(frame_hz == FRAME_HZ_LOCK, "frame rate must reduce to 10000000/333657")
    check(3 * 849 == 2547, "3*849 must be 2547")
    check(3 * 849 * 262 == 667_314, "3*849*262 must be 667314")
    check(667_314 // 2 == 333_657, "field den 333657 must be half of 667314")

    check(float(h_hz) > 15_600.0, "H must be above 15.6 kHz")
    check(float(h_hz) < 15_800.0, "H must stay under 15.8 kHz")
    check(float(field_hz) > 59.9, "field must be above 59.9 Hz")
    check(float(field_hz) < 60.0, "field must stay under 60.0 Hz")

    # Negative: 672x496 @ CE/2 is HDMI true480 ~30.002 Hz, not 15 kHz 480i.
    check(
        HDMI_FRAME_HZ == Fraction(78_125, 2_604),
        "HDMI true480 must reduce to 78125/2604",
    )
    check(HDMI_FRAME_HZ != frame_hz, "480i frame is not HDMI 672x496 CE/2")
    check(HDMI_FRAME_HZ != field_hz, "480i field is not HDMI 672x496 CE/2")
    check(h_total != HDMI_H_TOTAL, "480i H_TOTAL is not 672")
    check(V_FIELD != HDMI_V_TOTAL, "480i V field is not 496")
    check(CE_DEN != HDMI_CE_DEN or CE_NUM != 1, "480i CE is 2/3, not CE/2")
    check(abs(float(HDMI_FRAME_HZ) - 30.002) < 0.001, "HDMI true480 ~30.002 Hz")
    check(abs(float(frame_hz) - 30.002) > 0.02, "480i frame is not 30.002 Hz")
    hdmi_h = Fraction(SYSTEM_CLOCK_HZ, HDMI_CE_DEN * HDMI_H_TOTAL)
    check(hdmi_h == Fraction(625_000, 42), "HDMI true480 H is 10e6/672")
    check(float(hdmi_h) < 15_000.0, "HDMI true480 H is 14.88 kHz, not 15.7")
    check(h_hz != hdmi_h, "480i H is not the HDMI true480 line rate")
    # BT.601 858 at this 2/3 pix clock is not the lock (w-clock contract).
    h858 = Fraction(SYSTEM_CLOCK_HZ * CE_NUM, CE_DEN * 858)
    check(h858 != H_HZ_LOCK, "H=858 @ CE 2/3 is not 40000000/2547")
    check(h858 == Fraction(20_000_000, 1287), "H=858 @ 2/3 reduces to 20000000/1287")


def check_localparam_src(src: str, label: str, failures: list[str]) -> None:
    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    check(
        has_param(src, ("H_TOTAL", "P15K_I_H_TOTAL"), "849"),
        f"{label}: H_TOTAL must be 849",
    )
    check(
        has_param(src, ("V_TOTAL", "P15K_I_V_TOTAL"), "262"),
        f"{label}: V_TOTAL must be 262",
    )
    check(
        has_param(src, ("H_DE", "P15K_I_H_DE"), "640"),
        f"{label}: H_DE must be 640",
    )
    check(
        has_param(src, ("V_ACTIVE", "P15K_I_V_ACTIVE"), "240"),
        f"{label}: V_ACTIVE must be 240",
    )
    check(
        has_param(src, ("H_SYNC_S", "P15K_I_H_SYNC_S"), "660"),
        f"{label}: H_SYNC_S must be 660",
    )
    check(
        has_param(src, ("H_SYNC_E", "P15K_I_H_SYNC_E"), "723"),
        f"{label}: H_SYNC_E must be 723",
    )
    check(
        has_param(src, ("V_SYNC_S", "P15K_I_V_SYNC_S"), "243"),
        f"{label}: V_SYNC_S must be 243",
    )
    check(
        has_param(src, ("V_SYNC_E", "P15K_I_V_SYNC_E"), "246"),
        f"{label}: V_SYNC_E must be 246",
    )
    check(
        has_param(src, ("FRAME_LINES", "P15K_I_FRAME_LINES"), "524"),
        f"{label}: FRAME_LINES must be 524",
    )
    check(
        has_param(src, ("FIRST_ODD", "P15K_I_FIRST_ODD"), "1"),
        f"{label}: FIRST_ODD must be 1",
    )
    check(
        has_param(src, ("HALFLINE", "P15K_I_HALFLINE"), "0"),
        f"{label}: HALFLINE must be 0",
    )
    ce_ok = (
        has_param(src, ("CE_NUM", "P15K_I_CE_NUM"), "2")
        and has_param(src, ("CE_DEN", "P15K_I_CE_DEN"), "3")
    ) or ("CE 2/3" in src)
    check(ce_ok, f"{label}: CE must be 2/3")


def check_files(failures: list[str]) -> None:
    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    check(EXPECTED_CONST.is_file(), "expected_480i_cadence.txt missing")
    if EXPECTED_CONST.is_file():
        check_localparam_src(
            EXPECTED_CONST.read_text(encoding="utf-8"),
            "expected_480i_cadence.txt",
            failures,
        )

    for path, label in (
        (BEAM_SV, "present_beam_480i.sv"),
        (CONTRACT_SVH, "plex_15k_bw_contract.svh"),
    ):
        if path.is_file():
            check_localparam_src(path.read_text(encoding="utf-8"), label, failures)

    check(QSF_PRODUCT.is_file(), "product Plex.qsf missing")
    if QSF_PRODUCT.is_file():
        check(
            not qsf_enables(QSF_PRODUCT, "PLEX_PRESENT_480I"),
            "product QSF must NOT enable PLEX_PRESENT_480I",
        )
        check(
            qsf_enables(QSF_PRODUCT, "PLEX_PRESENT_TRUE_480P"),
            "product QSF still TRUE_480P",
        )
        check(
            not qsf_enables(QSF_PRODUCT, "PLEX_CLK_SYS_24"),
            "product QSF must not raise clk_sys",
        )

    if QSF_480I.is_file():
        check(
            qsf_enables(QSF_480I, "PLEX_PRESENT_480I"),
            "sibling Plex_480i.qsf must enable PLEX_PRESENT_480I",
        )
        check(
            qsf_enables(QSF_480I, "PLEX_PRESENT_TRUE_480P"),
            "sibling Plex_480i.qsf must enable TRUE_480P",
        )
        check(
            not qsf_enables(QSF_480I, "PLEX_PRESENT_240P15"),
            "sibling Plex_480i.qsf must not enable 240P15",
        )
        check(
            not qsf_enables(QSF_480I, "PLEX_CLK_SYS_24"),
            "sibling Plex_480i.qsf must not raise clk_sys",
        )

    if BOB_TEST.is_file() and BOB_SV.is_file():
        proc = subprocess.run(
            [sys.executable, str(BOB_TEST)],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        check(proc.returncode == 0, f"test_240p15_cadence rc={proc.returncode}")


def prove_red_twin(failures: list[str]) -> None:
    proc = subprocess.run(
        [sys.executable, str(Path(__file__).resolve()), "--red-twin-h858", "--math-only"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 1:
        failures.append(
            f"red twin H=858 must fail with rc=1, got rc={proc.returncode}"
        )
    err = proc.stderr or ""
    if "40000000/2547" not in err:
        failures.append("red twin H=858 must reject 40000000/2547")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--math-only",
        action="store_true",
        help="exact rationals only (no QSF/SV/self-red)",
    )
    parser.add_argument(
        "--red-twin-h858",
        action="store_true",
        help="L8: assert H_TOTAL=858 so 40000000/2547 must fail",
    )
    args = parser.parse_args(argv)

    failures: list[str] = []
    h_total = 858 if args.red_twin_h858 else H_TOTAL_LOCK
    check_math(h_total, failures)
    if not args.math_only and not args.red_twin_h858:
        check_files(failures)
        prove_red_twin(failures)

    if failures:
        print("FAIL test_480i_cadence:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    h_hz = Fraction(SYSTEM_CLOCK_HZ * CE_NUM, CE_DEN * H_TOTAL_LOCK)
    field_hz = Fraction(SYSTEM_CLOCK_HZ * CE_NUM, CE_DEN * H_TOTAL_LOCK * V_FIELD)
    frame_hz = field_hz / 2
    print(
        f"PASS test_480i_cadence H={float(h_hz):.3f} Hz "
        f"field={float(field_hz):.4f} Hz frame={float(frame_hz):.4f} Hz "
        f"{H_TOTAL_LOCK}x{V_FIELD} CE {CE_NUM}/{CE_DEN}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
