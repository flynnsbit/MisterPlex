#!/usr/bin/env python3
"""Fit-release gate: QSF macros + elab + true_de + architecture blockers.

Leg 0 — rd-duck architecture blockers (must clear before any fit grant):
        coherent FIT_CANDIDATE, no int FPS overflow cargo, real raster SoT,
        compile-time Option-C / layout match, PLXG ABA closed, ddr_frame_store
        exercised on the beam/clock path. Soft-skip ≠ PASS.
Leg 1 — active VERILOG_MACRO set from the QSF under test is the 720p ascal path
        (FRAME_W=960 FRAME_H=540 PRESENT_BEAM_960 DDR_FRAME_STORE). Hollow
        640×480 and commented-out macros fail here.
Leg 2 — verilator-elab with *exactly* that parsed macro set.
Leg 3 — counted true-DE RTL sim for the raster the QSF configures; true_de=1.

Source of truth for macros is the QSF Quartus reads. Architecture blockers are
source-scanned against this tree (quoted paths in FAIL lines).

Exit codes:
  0  all legs PASS (EXECUTED)
  1  a leg REJECTED
  2  usage / fixture / internal error
  3  Verilator missing (REFUSED — not a pass)
  77 never used as success
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_define_parity import discover_quartus_macros  # noqa: E402

DEFAULT_QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"
FIX = ROOT / "tests" / "fixtures" / "fit_release_gate"
CANDIDATE_PATHS = (
    ROOT / "docs" / "fit_candidate.json",
    ROOT / "assets" / "fit_candidate.json",
    FIX / "fit_candidate.json",
)
# Real hollow integration QSF (sibling worktree) — RED twin target.
HOLLOW_INTEG_QSF = Path(
    "/home/flynnsbit/Projects/MisterPlex-wt-integ-720p/fpga/Plex_MiSTer/Plex.qsf"
)
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
ALLOWED_ARCH = frozenset({"ascal_true_de_960", "mp_cea_1280"})

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
    "PRESENT_PX_PER_CLK, FABRIC_DDR_WRITER as features to enable. "
    "rd-duck: complex/mp path ≠ product until coherent FIT_CANDIDATE; "
    "40 Mpix/s bridge claim is not a product raster. Gate enforces one locked "
    "architecture + ascal-true-DE macro set when candidate=ascal_true_de_960."
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


def _read(path: Path) -> str:
    return path.read_text(errors="ignore") if path.is_file() else ""


def _layout_param(name: str) -> str | None:
    text = _read(RTL / "ddr_frame_layout_params.svh")
    m = re.search(rf"localparam\s+int\s+{re.escape(name)}\s*=\s*(\d+)", text)
    return m.group(1) if m else None


def leg0_arch_blockers() -> tuple[int, list[str]]:
    """rd-duck fit blockers — FAIL until a coherent candidate clears each.

    Evidence is quoted from this tree's source (rule 0). Checks auto-pass only
    when the cited defect is gone from the files.
    """
    msgs: list[str] = ["LEG0_ARCH_BLOCKERS_EXECUTED begin"]
    errors: list[str] = []

    # --- B0: one coherent FIT_CANDIDATE lock ---
    cand_path = next((p for p in CANDIDATE_PATHS if p.is_file()), None)
    cand: dict | None = None
    if cand_path is None:
        errors.append(
            "B0_NO_CANDIDATE: missing docs/fit_candidate.json (or assets/ / "
            "tests/fixtures/fit_release_gate/). Gate refuses fit until one "
            "architecture is locked with a tree hash. Allowed architecture: "
            + ",".join(sorted(ALLOWED_ARCH))
        )
    else:
        try:
            cand = json.loads(cand_path.read_text())
        except json.JSONDecodeError as e:
            errors.append(f"B0_BAD_CANDIDATE_JSON: {cand_path}: {e}")
            cand = None
        if cand is not None:
            arch = str(cand.get("architecture", ""))
            th = str(cand.get("git_tree_hash", cand.get("tree_hash", "")))
            msgs.append(f"LEG0_CANDIDATE path={cand_path} architecture={arch!r} hash={th!r}")
            if arch not in ALLOWED_ARCH:
                errors.append(
                    f"B0_BAD_ARCH: architecture={arch!r} not in {sorted(ALLOWED_ARCH)}"
                )
            if not re.fullmatch(r"[0-9a-f]{7,40}", th):
                errors.append(
                    "B0_BAD_HASH: git_tree_hash must be 7–40 hex chars naming the "
                    "coherent candidate tree (not empty)"
                )
            # Refuse dual-path cargo: candidate must not require both beams.
            req = cand.get("required_macros") or cand.get("qsf_macros") or {}
            if isinstance(req, dict):
                has_beam = str(req.get("PRESENT_BEAM_960", "")).lower() in {"1", "true"}
                has_mp = str(req.get("PRESENT_MULTI_PIXEL", "")).lower() in {"1", "true"}
                if has_beam and has_mp:
                    errors.append(
                        "B0_DUAL_PATH: candidate requires both PRESENT_BEAM_960 and "
                        "PRESENT_MULTI_PIXEL — pick one architecture"
                    )
                if arch == "ascal_true_de_960" and has_mp:
                    errors.append(
                        "B0_ASCAL_VS_MP: ascal_true_de_960 candidate must not enable "
                        "PRESENT_MULTI_PIXEL (rd-duck: complex/mp path separate)"
                    )
                if arch == "mp_cea_1280" and has_beam:
                    errors.append(
                        "B0_MP_VS_ASCAL: mp_cea_1280 candidate must not enable "
                        "PRESENT_BEAM_960"
                    )

    # --- B1: layout / compile-time Option-C vs FRAME 960 claim ---
    # Evidence: ddr_frame_layout_params.svh hardwires 480p presented; present_core
    # passes DDR_FRAME_* into ddr_frame_store; geom_enable=0 reloads LEG_* only.
    pw = _layout_param("DDR_FRAME_PRESENTED_WIDTH")
    ph = _layout_param("DDR_FRAME_PRESENTED_HEIGHT")
    cw = _layout_param("DDR_FRAME_CODED_WIDTH")
    ch = _layout_param("DDR_FRAME_CODED_HEIGHT")
    msgs.append(f"LEG0_LAYOUT presented={pw}x{ph} coded={cw}x{ch}")
    core = _read(RTL / "present_core.sv")
    store = _read(RTL / "ddr_frame_store.sv")
    if ".CODED_W(DDR_FRAME_CODED_WIDTH)" not in core:
        errors.append(
            "B1_PRESENT_CORE_WIRING: present_core.sv does not pass "
            ".CODED_W(DDR_FRAME_CODED_WIDTH) — cannot verify layout lock"
        )
    # geom-disabled branch hardwires legacy base/stride/doorbell (quoted).
    if "eff_base_w0    <= LEG_BASE_W0" not in store or "eff_doorbell_w <= LEG_DOORBELL_W" not in store:
        errors.append(
            "B1_GEOM_OFF_LEGACY_MARKERS_MOVED: expected geom_enable=0 path to assign "
            "LEG_BASE_W0/LEG_DOORBELL_W (ddr_frame_store.sv) — re-audit"
        )
    else:
        msgs.append(
            "LEG0_EVIDENCE geom_enable=0 assigns LEG_BASE_W0/LEG_DOORBELL_W "
            "(ddr_frame_store.sv) — no compile-time Option-C bank map"
        )
    # Compile-time Option-C does not exist: no ifdef selecting OPTC_* as localparam defaults.
    if re.search(r"`ifdef\s+FABRIC_NATIVE_720P_GEOM", store) is None and re.search(
        r"`ifdef\s+OPTION_C", store
    ) is None:
        if pw == "640" and ph == "480":
            errors.append(
                "B1_NO_COMPILE_TIME_OPTC: ddr_frame_layout_params.svh still "
                f"PRESENTED={pw}x{ph} CODED={cw}x{ch}; ddr_frame_store has no "
                "`ifdef FABRIC_NATIVE_720P_GEOM/OPTION_C compile-time bank path; "
                "geom_enable=0 stays legacy PHYS/stride/doorbell. FRAME_W=960 QSF "
                "alone does not re-base the store (rd-duck #3)."
            )
    if cand and cand.get("architecture") == "ascal_true_de_960":
        if pw != "960" or ph != "540":
            errors.append(
                f"B1_LAYOUT_NOT_960: candidate ascal_true_de_960 but layout params "
                f"PRESENTED={pw}x{ph} (need 960x540 compile-time match)"
            )

    # --- B2: scalar-ascal timing_960 constants-only + int overflow ---
    t960 = RTL / "present_video_timing_960.sv"
    t960_txt = _read(t960)
    if t960_txt:
        msgs.append(f"LEG0_EVIDENCE present_video_timing_960.sv exists ({t960.stat().st_size} B)")
        # Overflow: clock's 720p file documents and uses longint; 960 still uses int.
        if "localparam int FPS_MILLI = (CLK_PIX_HZ * 1000)" in t960_txt or re.search(
            r"localparam\s+int\s+FPS_MILLI\s*=\s*\(\s*CLK_PIX_HZ\s*\*\s*1000", t960_txt
        ):
            errors.append(
                "B2_FPS_INT_OVERFLOW: present_video_timing_960.sv uses "
                "`localparam int FPS_MILLI = (CLK_PIX_HZ * 1000) / …` — "
                "20_000_000*1000 overflows 32-bit signed int (rd-duck #2). "
                "present_video_timing_720p.sv already uses longint for this."
            )
        # No raster generator: no hc/vc counters; only assign of localparams.
        has_hc_reg = bool(re.search(r"\breg\s+\[[^\]]+\]\s*hc\b", t960_txt))
        has_always_raster = "always @(posedge" in t960_txt and has_hc_reg
        if not has_always_raster:
            errors.append(
                "B2_NO_RASTER_GENERATOR: present_video_timing_960.sv is constants-only "
                "(assign h_de/h_total/… from localparams; no hc/vc beam). Not a product "
                "raster (rd-duck #2). Product beam is present_beam_content_de with "
                "hardcoded totals — timing_960 is not wired as SoT."
            )
        # Not instantiated in present_core
        if "present_video_timing_960" not in core:
            msgs.append(
                "LEG0_EVIDENCE present_core.sv does not instantiate present_video_timing_960"
            )
        qip = _read(ROOT / "fpga" / "Plex_MiSTer" / "files.qip")
        if "present_video_timing_960.sv" in qip and not has_always_raster:
            errors.append(
                "B2_TIMING960_IN_QIP_WITHOUT_RASTER: constants module listed in files.qip "
                "without being a real generator — cargo risk"
            )
        # 40 Mpix claim is not product raster (doc budget line).
        dec = _read(ROOT / "docs" / "product-4-3-scaler-decision.md")
        if "40 Mpix/s" in dec or "40 Mpix" in dec:
            if cand is None or cand.get("architecture") != "mp_cea_1280":
                errors.append(
                    "B1_40MPIX_NOT_PRODUCT: docs/product-4-3-scaler-decision.md cites "
                    "w-clock 40 Mpix/s bridge; rd-duck: nominal 40 Mpix/s is not product "
                    "unless FIT_CANDIDATE architecture=mp_cea_1280 with real clk_pix path. "
                    "ascal_true_de_960 product rate is ~15.55 Mpix/s content @30."
                )

    # --- B4: PLXG same-seq ABA remains in FPGA latch ---
    latch = _read(RTL / "present_geom_latch.sv")
    if latch:
        if "seq_new  = magic_ok && (sh_seq != last_seq)" in latch or re.search(
            r"seq_new\s*=\s*magic_ok\s*&&\s*\(\s*sh_seq\s*!=\s*last_seq\s*\)", latch
        ):
            # Still no session/epoch distinct from seq — restart same-seq ABA class.
            if "epoch" not in latch and "session_id" not in latch and "generation" not in latch:
                errors.append(
                    "B4_PLXG_SAME_SEQ_ABA: present_geom_latch.sv accepts commit only when "
                    "`sh_seq != last_seq` with no epoch/session token. After FPGA reset "
                    "last_seq=0, retained DDR q0 seq=N can ABA on restart "
                    "(rd-duck #4; host plxg_record.hpp documents the class — RTL still open)."
                )
            else:
                msgs.append("LEG0_PLXG: epoch/session marker present — ABA check soft-clear")
        else:
            msgs.append("LEG0_PLXG: seq_new pattern changed — re-audit ABA")

    # --- B5: no test uses real ddr_frame_store on beam/clock path ---
    tests_root = ROOT / "tests"
    beam_ddr_tests: list[str] = []
    for path in tests_root.rglob("*"):
        if not path.is_file() or path.suffix not in {".sv", ".sh", ".cpp", ".py"}:
            continue
        txt = _read(path)
        has_ddr = "ddr_frame_store" in txt
        has_beam = ("present_beam_content_de" in txt) or ("PRESENT_BEAM_960" in txt)
        if has_ddr and has_beam:
            beam_ddr_tests.append(str(path.relative_to(ROOT)))
    if not beam_ddr_tests:
        errors.append(
            "B5_NO_DDR_ON_BEAM_TEST: no test under tests/ instantiates/drives "
            "ddr_frame_store together with present_beam_content_de/PRESENT_BEAM_960 "
            "(rd-duck #5). true_de_count covers beam+window only — not the store path."
        )
    else:
        msgs.append("LEG0_DDR_BEAM_TESTS " + " ".join(beam_ddr_tests))

    # --- Runtime-OFF OSD / colorbars timing cargo when candidate is ascal ---
    if cand and cand.get("architecture") == "ascal_true_de_960":
        # present_core still has colorbars Template path when PRESENT_BEAM_960 undefined.
        if "`else" in core and "colorbars bars" in core and "PRESENT_BEAM_960" in core:
            msgs.append(
                "LEG0_NOTE: colorbars Template path remains under `ifndef PRESENT_BEAM_960` "
                "— acceptable only if QSF forces PRESENT_BEAM_960=1 (leg1) and candidate "
                "forbids shipping without it"
            )
        # Reject candidate that leaves beam default-OFF as ship.
        req = cand.get("required_macros") or cand.get("qsf_macros") or {}
        if isinstance(req, dict) and str(req.get("PRESENT_BEAM_960", "")) not in {"1", "true"}:
            errors.append(
                "B0_BEAM_RUNTIME_OFF_CARGO: ascal_true_de_960 candidate must list "
                "PRESENT_BEAM_960=1 as required (no runtime-OFF beam / Template DE cargo)"
            )

    if errors:
        msgs.append("LEG0_FAIL EXECUTED reasons:")
        msgs.extend(f"  - {e}" for e in errors)
        msgs.append(f"LEG0_FAIL count={len(errors)}")
        return 1, msgs

    msgs.append("LEG0_PASS EXECUTED architecture blockers clear")
    return 0, msgs


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
    skip_arch: bool = False,
    skip_elab: bool = False,
    skip_true_de: bool = False,
    force_island: bool = False,
) -> int:
    print(CROSS_LANE)
    print(f"FIT_RELEASE_GATE qsf={qsf}")
    print("FIT_RELEASE_GATE_EXECUTED begin")

    if not skip_arch:
        rc0, msgs0 = leg0_arch_blockers()
        print("\n".join(msgs0))
        print(f"leg0 true rc={rc0}")
        if rc0 != 0:
            print("FIT_RELEASE_GATE_FAIL leg=0 (architecture blockers / rd-duck)")
            return rc0
    else:
        print("LEG0_SKIP isolation path — not valid for fit grant")

    rc1, msgs1, active = leg1_macros(qsf)
    print("\n".join(msgs1))
    print(f"leg1 true rc={rc1}")
    if rc1 != 0:
        print("FIT_RELEASE_GATE_FAIL leg=1 (macros)")
        return rc1

    if skip_elab:
        print("LEG2_SKIP requested — not a pass path for release")
        return 1

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

    if skip_arch:
        print("FIT_RELEASE_GATE_PASS EXECUTED legs=1+2+3 (arch skipped — NOT a fit grant)")
    else:
        print("FIT_RELEASE_GATE_PASS EXECUTED legs=0+1+2+3")
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
    """Mandatory RED twins + isolation GREEN + full-gate arch RED. Each EXECUTED."""
    print("FIT_RELEASE_GATE_SELFTEST_EXECUTED begin")
    fx = ensure_fixtures()
    failures = 0

    def expect(
        label: str,
        qsf: Path,
        want_rc: int,
        *,
        force_island: bool = False,
        legs: str = "all",
    ) -> None:
        nonlocal failures
        print(f"\n=== SELFTEST {label} want_rc={want_rc} ===")
        if legs == "leg0":
            rc, msgs = leg0_arch_blockers()
            print("\n".join(msgs))
            print(f"{label} true rc={rc}")
        elif legs == "leg1":
            rc, msgs, _ = leg1_macros(qsf)
            print("\n".join(msgs))
            print(f"{label} true rc={rc}")
        elif legs == "leg1+3island":
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
        elif legs == "macros_elab_tde":
            # Isolation: prove legs 1–3 can go green without claiming fit grant.
            rc = run_gate(qsf, skip_arch=True, force_island=force_island)
            print(f"{label} gate true rc={rc}")
        else:
            rc = run_gate(qsf, force_island=force_island)
            print(f"{label} gate true rc={rc}")
        if rc != want_rc:
            print(f"FAIL {label}: rc={rc} want={want_rc}")
            failures += 1
        else:
            print(f"PASS SELFTEST {label} EXECUTED rc={rc}")

    # rd-duck arch blockers must FAIL on today's tree (not soft-skip).
    expect("arch_blockers_open", fx["green"], 1, legs="leg0")

    hollow = HOLLOW_INTEG_QSF if HOLLOW_INTEG_QSF.is_file() else None
    if hollow is None:
        print("FAIL SELFTEST hollow: integ QSF path missing")
        failures += 1
    else:
        expect("hollow_integ_720p", hollow, 1, legs="leg1")

    expect("commented_beam", fx["commented"], 1, legs="leg1")
    expect("mismatch_960x480", fx["mismatch"], 1, legs="leg1")

    rc_dup, msgs_dup, act_dup = leg1_macros(fx["dup"])
    print("\n".join(msgs_dup))
    print(f"dup_last_wins true rc={rc_dup}")
    if rc_dup != 0 or act_dup.get("FRAME_W") != "960" or act_dup.get("FRAME_H") != "540":
        print(
            f"FAIL dup_last_wins: rc={rc_dup} FRAME={act_dup.get('FRAME_W')}x{act_dup.get('FRAME_H')}"
        )
        failures += 1
    else:
        print("PASS SELFTEST dup_last_wins EXECUTED last=960x540")

    expect("island_fault_in_qsf", fx["island"], 1, legs="leg1")
    expect("island_leg3_independent", fx["green"], 1, legs="leg1+3island")

    # Legs 1–3 isolation GREEN (constructed fixture) — does NOT authorize fit.
    expect("green_macros_elab_tde_isolation", fx["green"], 0, legs="macros_elab_tde")

    # Full gate on green fixture must still FAIL while arch blockers open (rd-duck).
    expect("full_gate_blocked_by_arch", fx["green"], 1, legs="all")

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
    ap.add_argument(
        "--skip-arch",
        action="store_true",
        help="Isolation only: skip leg0 architecture blockers (NOT a fit grant)",
    )
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    return run_gate(
        args.qsf.resolve(),
        skip_arch=args.skip_arch,
        force_island=args.force_island_leg3,
    )


if __name__ == "__main__":
    raise SystemExit(main())
