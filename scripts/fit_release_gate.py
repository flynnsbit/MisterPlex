#!/usr/bin/env python3
"""Fit-release gate: one command, three independent legs, QSF is SoT.

Leg 1 — active VERILOG_MACRO set from the QSF under test is the 720p ascal path
        (FRAME_W=960 FRAME_H=540 PRESENT_BEAM_960 DDR_FRAME_STORE). Hollow
        640×480 and commented-out macros fail here.
Leg 2 — verilator-elab with *exactly* that parsed macro set (not the hollow
        default still sitting in a sibling worktree's live QSF).
Leg 3 — counted true-DE RTL sim for the raster the QSF configures; require
        true_de=1 (DE extent == content extent). Soft-skip ≠ PASS.

Source of truth is the QSF Quartus reads. A hardcoded macro list would
reproduce the hollow-elaboration defect one level up.

Exit codes:
  0  all legs PASS (EXECUTED)
  1  a leg REJECTED
  2  usage / fixture / internal error
  3  Verilator missing (REFUSED — not a pass)
  77 never used as success
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_define_parity import discover_quartus_macros  # noqa: E402

DEFAULT_QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"
FIX = ROOT / "tests" / "fixtures" / "fit_release_gate"
# Real hollow integration QSF (sibling worktree) — RED twin target.
HOLLOW_INTEG_QSF = Path(
    "/home/flynnsbit/Projects/MisterPlex-wt-integ-720p/fpga/Plex_MiSTer/Plex.qsf"
)

# Required for ascal-native 960×540 content DE fit (docs/ascal-true-de-fit-card.md).
REQUIRED_EXACT = {
    "FRAME_W": "960",
    "FRAME_H": "540",
    "PRESENT_BEAM_960": "1",
    "DDR_FRAME_STORE": "1",
}
# Known-hollow values that must not be the active assignment.
FORBIDDEN_VALUES = {
    "FRAME_W": {"640"},
    "FRAME_H": {"480"},
}
# Fault / non-product macros must stay out of a release QSF.
FORBIDDEN_PRESENT = {
    "PRESENT_BEAM_FAULT_ISLAND_1280",
    "PRESENT_BEAM_FAULT_VTOT_BAD_DE",
}

# Cross-lane note (printed on every run — do not silently resolve):
CROSS_LANE = (
    "CROSS_LANE_MACRO_NOTE: w-scaler fit card (docs/ascal-true-de-fit-card.md) "
    "requires PRESENT_BEAM_960 + FRAME 960/540 and says do NOT set "
    "PRESENT_MULTI_PIXEL / PRESENT_SCALE_4_3 / PRESENT_SCALE_2X for this path. "
    "integ/fab-720p-planes QSF comments list PRESENT_MULTI_PIXEL, "
    "PRESENT_PX_PER_CLK, FABRIC_DDR_WRITER as features to enable. This gate "
    "enforces the scaler ascal-true-DE set only; multi-pixel/fabric-writer are "
    "NOT required here."
)


def _run(cmd: list[str], *, cwd: Path | None = None, env: dict | None = None) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd or ROOT),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return proc.returncode, proc.stdout


def leg1_macros(qsf: Path) -> tuple[int, list[str], dict[str, str]]:
    """Return (rc, messages, name->value). rc=0 PASS."""
    msgs: list[str] = []
    if not qsf.is_file():
        return 2, [f"LEG1_ERROR: QSF not found: {qsf}"], {}

    macros = discover_quartus_macros(qsf)
    # Drop BUILD_DATE synthetic from parity helper for fit-gate view.
    active = {n: m.value for n, m in macros.items() if n != "BUILD_DATE"}
    msgs.append(f"LEG1_QSF={qsf}")
    msgs.append(
        "LEG1_ACTIVE_MACROS "
        + " ".join(f"{k}={v}" for k, v in sorted(active.items()))
    )
    msgs.append("LEG1_MACRO_PARSE_RULE=hash_comment_absent last_wins")

    errors: list[str] = []
    for name, want in REQUIRED_EXACT.items():
        got = active.get(name)
        if got is None:
            errors.append(f"missing required {name}={want}")
        elif got != want:
            errors.append(f"{name}={got!r} want {want!r} (source {macros[name].source})")

    for name, bad_vals in FORBIDDEN_VALUES.items():
        got = active.get(name)
        if got in bad_vals:
            errors.append(f"hollow/forbidden {name}={got} (must not ship)")

    # Mismatched pair: W correct but H wrong (or vice versa) — already covered by
    # REQUIRED_EXACT, but name it explicitly for the adversarial case.
    fw, fh = active.get("FRAME_W"), active.get("FRAME_H")
    if fw == "960" and fh is not None and fh != "540":
        errors.append(f"mismatched FRAME pair FRAME_W=960 FRAME_H={fh} (need 540)")
    if fh == "540" and fw is not None and fw != "960":
        errors.append(f"mismatched FRAME pair FRAME_W={fw} FRAME_H=540 (need 960)")

    for name in sorted(FORBIDDEN_PRESENT):
        if name in active:
            errors.append(f"forbidden fault/non-product macro present: {name}={active[name]}")

    if errors:
        msgs.append("LEG1_FAIL EXECUTED reasons:")
        msgs.extend(f"  - {e}" for e in errors)
        return 1, msgs, active

    msgs.append(
        "LEG1_PASS EXECUTED required={FRAME_W=960,FRAME_H=540,PRESENT_BEAM_960=1,DDR_FRAME_STORE=1} "
        "hollow_640_480=absent"
    )
    return 0, msgs, active


def leg2_elab(qsf: Path) -> tuple[int, list[str]]:
    msgs: list[str] = []
    elab = ROOT / "scripts" / "check_verilator_elab.py"
    rc, out = _run([sys.executable, str(elab), "--qsf", str(qsf)])
    msgs.append(out.rstrip())
    msgs.append(f"leg2_elab true rc={rc}")
    if rc == 3:
        msgs.append("LEG2_REFUSED EXECUTED Verilator missing (not a pass)")
        return 3, msgs
    if rc != 0:
        msgs.append("LEG2_FAIL EXECUTED verilator-elab rejected with fit macro set")
        return 1, msgs
    if "VERILATOR_ELAB_PASS" not in out:
        msgs.append("LEG2_FAIL EXECUTED missing VERILATOR_ELAB_PASS token")
        return 1, msgs
    # Prove the fit macros were actually injected (not hollow default alone).
    if "propagated QSF macros" not in out:
        msgs.append("LEG2_FAIL EXECUTED no macro propagation line")
        return 1, msgs
    msgs.append("LEG2_PASS EXECUTED verilator-elab with QSF macro set")
    return 0, msgs


def leg3_true_de(
    active: dict[str, str],
    *,
    force_island: bool = False,
    work: Path | None = None,
) -> tuple[int, list[str]]:
    """Counted true-DE sim for the raster implied by active macros."""
    msgs: list[str] = []
    fw = int(active.get("FRAME_W", "0") or "0")
    fh = int(active.get("FRAME_H", "0") or "0")
    if fw <= 0 or fh <= 0:
        return 1, ["LEG3_FAIL EXECUTED FRAME_W/H not available from leg1 parse"]

    island = force_island or ("PRESENT_BEAM_FAULT_ISLAND_1280" in active)
    run = ROOT / "scripts" / "run_verilator.sh"
    # Probe verilator
    vrc, vout = _run([str(run), "--version"])
    if vrc == 127:
        msgs.append("LEG3_REFUSED EXECUTED Verilator missing (not a pass)")
        return 3, msgs
    if vrc != 0:
        msgs.append(vout)
        msgs.append(f"LEG3_ERROR verilator probe rc={vrc}")
        return vrc, msgs

    mdir = work or (ROOT / "build" / "fit_release_gate" / "true_de")
    if mdir.exists():
        shutil.rmtree(mdir)
    mdir.mkdir(parents=True, exist_ok=True)

    sv = [
        str(ROOT / "tests" / "rtl" / "present_true_de_count_tb_top.sv"),
        str(ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "present_beam_content_de.sv"),
        str(ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "present_content_window.sv"),
        str(ROOT / "tests" / "rtl" / "present_true_de_count_tb.cpp"),
    ]
    # Verilator wants `-CFLAGS` and its value as *two* argv tokens (see unit sim).
    cflags = f"-std=c++17 -O2 -DFIT_GATE_CW={fw} -DFIT_GATE_CH={fh}"
    if island:
        cflags += " -DPRESENT_BEAM_FAULT_ISLAND_1280"
    cmd = [
        str(run),
        "--cc",
        "--exe",
        "--build",
        "--top-module",
        "present_true_de_count_tb",
        "-Wno-fatal",
        "-Wno-WIDTHEXPAND",
        "-Wno-WIDTHTRUNC",
        "-CFLAGS",
        cflags,
        "--Mdir",
        str(mdir),
    ]
    if island:
        cmd.append("+define+PRESENT_BEAM_FAULT_ISLAND_1280")
    cmd.extend(sv)

    brc, bout = _run(cmd)
    msgs.append(bout.rstrip())
    msgs.append(f"leg3_build true rc={brc}")
    if brc != 0:
        msgs.append("LEG3_FAIL EXECUTED verilator build failed")
        return 1, msgs

    bin_path = mdir / "Vpresent_true_de_count_tb"
    rrc, rout = _run([str(bin_path)])
    msgs.append(rout.rstrip())
    msgs.append(f"leg3_sim true rc={rrc}")

    if "CASE true_de_count EXECUTED" not in rout:
        msgs.append("LEG3_FAIL EXECUTED missing CASE true_de_count EXECUTED")
        return 1, msgs

    # Require true_de=1 for the configured content raster.
    m = re.search(r"true_de=(\d+)", rout)
    de_w = re.search(r"de_w_max=(\d+)", rout)
    de_h = re.search(r"de_lines=(\d+)", rout)
    if not m or not de_w or not de_h:
        msgs.append("LEG3_FAIL EXECUTED could not parse true_de/de_w/de_lines")
        return 1, msgs

    td, dw, dh = int(m.group(1)), int(de_w.group(1)), int(de_h.group(1))
    msgs.append(
        f"LEG3_MEASURE content={fw}x{fh} de={dw}x{dh} true_de={td} island_inject={int(island)}"
    )

    if island:
        # Independence twin: must EXECUTE and show true_de=0 (not pass).
        if td != 0 or rrc == 0:
            msgs.append(
                f"LEG3_FAIL EXECUTED island inject expected true_de=0 rc!=0 got true_de={td} rc={rrc}"
            )
            return 1, msgs
        msgs.append("LEG3_INDEPENDENT_ISLAND_RED EXECUTED true_de=0 (leg3 alone rejects)")
        # For the normal gate path, island means FAIL the release gate.
        msgs.append("LEG3_FAIL EXECUTED island/true_de=0 — release blocked")
        return 1, msgs

    if rrc != 0 or td != 1 or dw != fw or dh != fh:
        msgs.append(
            f"LEG3_FAIL EXECUTED need true_de=1 de={fw}x{fh} rc=0; "
            f"got true_de={td} de={dw}x{dh} rc={rrc}"
        )
        return 1, msgs

    msgs.append(f"LEG3_PASS EXECUTED true_de=1 de={dw}x{dh} content={fw}x{fh}")
    return 0, msgs


def run_gate(
    qsf: Path,
    *,
    skip_elab: bool = False,
    skip_true_de: bool = False,
    force_island: bool = False,
) -> int:
    print(CROSS_LANE)
    print(f"FIT_RELEASE_GATE qsf={qsf}")
    print("FIT_RELEASE_GATE_EXECUTED begin")

    rc1, msgs1, active = leg1_macros(qsf)
    print("\n".join(msgs1))
    print(f"leg1 true rc={rc1}")
    if rc1 != 0:
        print("FIT_RELEASE_GATE_FAIL leg=1 (macros)")
        return rc1

    if skip_elab:
        print("LEG2_SKIP requested — not a pass path for release")
        rc2 = 1
    else:
        rc2, msgs2 = leg2_elab(qsf)
        print("\n".join(msgs2))
        print(f"leg2 true rc={rc2}")
        if rc2 != 0:
            print("FIT_RELEASE_GATE_FAIL leg=2 (verilator-elab)")
            return rc2

    if skip_true_de:
        print("LEG3_SKIP requested — not a pass path for release")
        return 1

    rc3, msgs3 = leg3_true_de(active, force_island=force_island)
    print("\n".join(msgs3))
    print(f"leg3 true rc={rc3}")
    if rc3 != 0:
        print("FIT_RELEASE_GATE_FAIL leg=3 (true_de)")
        return rc3

    print("FIT_RELEASE_GATE_PASS EXECUTED legs=1+2+3")
    return 0


def _write_fixture(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def ensure_fixtures() -> dict[str, Path]:
    """Construct adversarial + green QSF fixtures (not the real integ QSF)."""
    FIX.mkdir(parents=True, exist_ok=True)
    fixtures: dict[str, Path] = {}

    green = FIX / "green_ascal_960x540.qsf"
    _write_fixture(
        green,
        """# CONSTRUCTED fixture for fit-release gate GREEN path — NOT the live integ QSF.
# Unique marker: FITGATE_FIXTURE_GREEN_ASCAL_960_20260803
set_global_assignment -name VERILOG_MACRO "SDRAM_CLK_142=1"
set_global_assignment -name VERILOG_MACRO "SDRAM_CL3=1"
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
set_global_assignment -name VERILOG_MACRO "FRAME_LINES_8=1"
set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["green"] = green

    commented = FIX / "red_commented_beam.qsf"
    _write_fixture(
        commented,
        """# RED: required macros present only as comments → must read ABSENT
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
# set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["commented"] = commented

    mismatch = FIX / "red_mismatch_960x480.qsf"
    _write_fixture(
        mismatch,
        """# RED: mismatched pair — W right, H hollow
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=480"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["mismatch"] = mismatch

    dup = FIX / "dup_last_wins.qsf"
    _write_fixture(
        dup,
        """# last-wins: hollow first, correct second
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=640"
set_global_assignment -name VERILOG_MACRO "FRAME_H=480"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
""",
    )
    fixtures["dup"] = dup

    island = FIX / "red_island_fault_macro.qsf"
    _write_fixture(
        island,
        """# Otherwise-green macros + island fault — leg3 must reject true_de
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_FAULT_ISLAND_1280=1"
""",
    )
    fixtures["island"] = island
    return fixtures


def self_test() -> int:
    """Mandatory RED twins + GREEN. Each case prints EXECUTED."""
    print("FIT_RELEASE_GATE_SELFTEST_EXECUTED begin")
    fx = ensure_fixtures()
    failures = 0

    def expect(label: str, qsf: Path, want_rc: int, *, force_island: bool = False, legs: str = "all") -> None:
        nonlocal failures
        print(f"\n=== SELFTEST {label} want_rc={want_rc} ===")
        if legs == "leg1":
            rc, msgs, _ = leg1_macros(qsf)
            print("\n".join(msgs))
            print(f"{label} true rc={rc}")
        elif legs == "leg1+3island":
            # Independence: leg1 on green, leg3 forced island → leg3 fails alone.
            rc1, msgs1, active = leg1_macros(qsf)
            print("\n".join(msgs1))
            print(f"{label}_leg1 true rc={rc1}")
            if rc1 != 0:
                print(f"FAIL {label}: leg1 should PASS on green fixture")
                failures += 1
                return
            rc3, msgs3 = leg3_true_de(active, force_island=True)
            print("\n".join(msgs3))
            print(f"{label}_leg3 true rc={rc3}")
            rc = rc3
        else:
            rc = run_gate(qsf, force_island=force_island)
            print(f"{label} gate true rc={rc}")
        if rc != want_rc:
            print(f"FAIL {label}: rc={rc} want={want_rc}")
            failures += 1
        else:
            print(f"PASS SELFTEST {label} EXECUTED rc={rc}")

    # P1 hollow real integ QSF
    hollow = HOLLOW_INTEG_QSF if HOLLOW_INTEG_QSF.is_file() else None
    if hollow is None:
        print("FAIL SELFTEST hollow: integ QSF path missing")
        failures += 1
    else:
        expect("hollow_integ_720p", hollow, 1, legs="leg1")

    expect("commented_beam", fx["commented"], 1, legs="leg1")
    expect("mismatch_960x480", fx["mismatch"], 1, legs="leg1")

    # last-wins: leg1 must PASS (960/540 wins)
    rc_dup, msgs_dup, act_dup = leg1_macros(fx["dup"])
    print("\n".join(msgs_dup))
    print(f"dup_last_wins true rc={rc_dup}")
    if rc_dup != 0 or act_dup.get("FRAME_W") != "960" or act_dup.get("FRAME_H") != "540":
        print(f"FAIL dup_last_wins: rc={rc_dup} FRAME={act_dup.get('FRAME_W')}x{act_dup.get('FRAME_H')}")
        failures += 1
    else:
        print("PASS SELFTEST dup_last_wins EXECUTED last=960x540")

    # Island fault macro in QSF → leg1 forbids FAULT (release QSF must not carry it)
    expect("island_fault_in_qsf", fx["island"], 1, legs="leg1")

    # Independence: legs 1 green, leg3 island inject fails alone
    expect("island_leg3_independent", fx["green"], 1, legs="leg1+3island")

    # Full green path
    expect("green_ascal_960x540", fx["green"], 0)

    if failures:
        print(f"FIT_RELEASE_GATE_SELFTEST_FAIL failures={failures}")
        return 1
    print("FIT_RELEASE_GATE_SELFTEST_PASS EXECUTED")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--qsf",
        type=Path,
        default=DEFAULT_QSF,
        help="Quartus settings file to parse (default: project Plex.qsf)",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="Run RED/GREEN adversarial suite (mandatory acceptance)",
    )
    ap.add_argument(
        "--force-island-leg3",
        action="store_true",
        help="Inject island beam into leg3 (independence / red twin)",
    )
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    return run_gate(args.qsf.resolve(), force_island=args.force_island_leg3)


if __name__ == "__main__":
    raise SystemExit(main())
