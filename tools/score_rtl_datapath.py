#!/usr/bin/env python3
"""RTL Datapath Grading Ratchet — grades the FPGA decode pipeline as it grows.

This is the INDEPENDENT grader of the decode datapath. It measures what the
RTL actually covers, enforces monotonic coverage (can only go UP), and reports
per-stage per-plane with [RTL]/[HOST] labels on every line.

Design principles (from instrument-integrity failures #14-#19):
- Coverage is a FIRST-CLASS output, on the same line as the score.
- Per-stage, NEVER aggregated. Luma and chroma must never collapse into one number.
- Degeneracy assertion: if reference produced no change, test FAILS.
- Monotonic: coverage may only increase. A commit reducing coverage is HARD FAIL.
- [RTL] or [HOST] on every line. No ambiguity about what is being measured.
- Expect RED. A full-green result against a pipeline missing intra prediction,
  chroma reconstruction and deblocking is evidence the instrument is broken.

Usage:
  python3 tools/score_rtl_datapath.py --ratchet tests/fixtures/rtl_datapath_ratchet_v1.json

Requires: Verilator simulation results from test_stream_path_full_frame_compare.sh
  or direct RTL module driving.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERILATOR = os.environ.get(
    "VERILATOR_BIN",
    str(Path.home() / ".local/oss-cad-suite-20260726/bin/verilator"),
)


def refuse(msg: str, rc: int = 9) -> None:
    """Refuse loudly with distinct rc. A soft skip is NEVER a pass."""
    print(f"REFUSE (rc={rc}): {msg}", file=sys.stderr)
    sys.exit(rc)


def check_verilator() -> None:
    """Gate: Verilator must exist or we refuse. Never silently pass."""
    if not os.path.isfile(VERILATOR):
        refuse(f"Verilator not found at {VERILATOR}. Cannot grade RTL without simulator.")


def load_ratchet(path: str) -> dict:
    """Load and validate ratchet file."""
    with open(path) as f:
        ratchet = json.load(f)
    if ratchet.get("format") != "misterplex.p3.rtl_datapath_ratchet.v1":
        refuse(f"Unknown ratchet format: {ratchet.get('format')}")
    if ratchet.get("verification_target") != "RTL":
        refuse(f"Ratchet verification_target is not RTL: {ratchet.get('verification_target')}")
    return ratchet


def grade_luma_residual(ratchet: dict) -> dict:
    """Grade the luma residual stage using existing dequant QP sweep.

    This is [RTL]: it drives h264_dequant4x4 -> h264_idct4x4 -> h264_recon4x4
    through Verilator with functional stimulus.
    """
    # Run the dequant sweep test
    sweep_script = ROOT / "tests/unit/test_dequant_qp_sweep.py"
    if not sweep_script.exists():
        return {"status": "SKIP", "reason": "test_dequant_qp_sweep.py not found"}

    result = subprocess.run(
        [sys.executable, str(sweep_script)],
        capture_output=True, text=True, timeout=120,
        cwd=str(ROOT),
    )

    if result.returncode != 0:
        return {
            "status": "FAIL",
            "level": "[RTL]",
            "detail": result.stderr[-500:] if result.stderr else "no output",
        }

    # Parse output for degeneracy check
    nontrivial = 0
    tests = 0
    for line in result.stdout.splitlines():
        if "nontrivial output" in line:
            parts = line.split()
            for p in parts:
                if "/" in p:
                    try:
                        nontrivial = int(p.split("/")[0])
                        tests = int(p.split("/")[1])
                    except ValueError:
                        pass
        if "PASS:" in line and "tests" in line:
            for p in line.split():
                try:
                    tests = max(tests, int(p))
                except ValueError:
                    pass

    return {
        "status": "PASS" if result.returncode == 0 else "FAIL",
        "level": "[RTL]",
        "tests_exact": tests,
        "nontrivial": nontrivial,
        "blocks_covered": 1,
        "pixels_covered": 16,
        "mbs_covered": 1,
        "stage": "luma_residual",
    }


def grade_luma_reconstruction(ratchet: dict) -> dict:
    """Grade luma reconstruction via the intra frame Verilator test.

    This is [RTL]: it drives h264_recon4x4 through Verilator for all 300 MBs
    with correct prediction + correct residual. Module-level, not pipeline-level.
    """
    frame_script = ROOT / "tests/unit/test_p3_intra_frame_verilator.py"
    if not frame_script.exists():
        return {"status": "SKIP", "reason": "test_p3_intra_frame_verilator.py not found"}

    result = subprocess.run(
        [sys.executable, str(frame_script)],
        capture_output=True, text=True, timeout=120,
        cwd=str(ROOT),
    )

    mb_exact = 0
    mb_total = 0
    recon_differed = 0
    for line in result.stdout.splitlines():
        if "mb_exact=" in line:
            for token in line.split():
                if token.startswith("mb_exact="):
                    parts = token.split("=")[1].split("/")
                    mb_exact = int(parts[0])
                    mb_total = int(parts[1])
                if token.startswith("recon_differed_from_pred="):
                    recon_differed = int(token.split("=")[1])

    pixels_covered = mb_exact * 256  # 16x16 luma pixels per MB
    blocks_covered = mb_exact * 16   # 16 4x4 blocks per MB

    return {
        "status": "PASS" if result.returncode == 0 else "FAIL",
        "level": "[RTL]",
        "mb_exact": mb_exact,
        "mb_total": mb_total,
        "pixels_covered": pixels_covered,
        "blocks_covered": blocks_covered,
        "mbs_covered": mb_exact,
        "recon_differed_from_pred": recon_differed,
        "degeneracy_ok": recon_differed > 0,
        "stage": "luma_reconstruction",
        "note": "Module-level: drives RTL recon individually per block, not through integrated pipeline",
    }


def grade_unimplemented_stage(stage_name: str, ratchet: dict) -> dict:
    """Grade a stage known to be unimplemented. Reports 0 coverage honestly."""
    stage_info = ratchet["stages"].get(stage_name, {})
    return {
        "status": "NOT_IMPLEMENTED",
        "level": "[RTL]",
        "pixels_covered": 0,
        "blocks_covered": 0,
        "mbs_covered": 0,
        "stage": stage_name,
        "note": stage_info.get("notes", "Not instantiated in decode pipeline"),
    }


def check_monotonic(stage_name: str, measured: dict, ratchet: dict) -> list:
    """Check that coverage has not regressed below ratchet minimum."""
    failures = []
    stage_ratchet = ratchet["stages"].get(stage_name, {})

    for key in ("min_blocks_exact", "min_pixels_exact", "min_mbs_covered"):
        ratchet_val = stage_ratchet.get(key, 0)
        measured_key = key.replace("min_", "").replace("_exact", "_covered")
        if "blocks" in key:
            measured_key = "blocks_covered"
        elif "pixels" in key:
            measured_key = "pixels_covered"
        elif "mbs" in key:
            measured_key = "mbs_covered"

        measured_val = measured.get(measured_key, 0)
        if measured_val < ratchet_val:
            failures.append(
                f"RATCHET REGRESSION {stage_name}: {measured_key}={measured_val} "
                f"< min={ratchet_val}"
            )

    # Degeneracy check
    degen_min = stage_ratchet.get("degeneracy_min_nontrivial", 0)
    nontrivial = measured.get("nontrivial", measured.get("recon_differed_from_pred", 0))
    if degen_min > 0 and nontrivial < degen_min:
        failures.append(
            f"DEGENERATE {stage_name}: nontrivial={nontrivial} < min={degen_min}"
        )

    return failures


def main():
    parser = argparse.ArgumentParser(description="RTL Datapath Grading Ratchet")
    parser.add_argument("--ratchet", required=True, help="Path to ratchet JSON")
    parser.add_argument("--output", help="Path to write JSON results")
    args = parser.parse_args()

    check_verilator()
    ratchet = load_ratchet(args.ratchet)

    results = {}
    failures = []

    # Grade implemented stages
    print("=" * 72)
    print("RTL DATAPATH GRADING RATCHET")
    print("verification_target=RTL  host_involvement=golden_reference_only")
    print("=" * 72)

    # Stage 1: Luma residual (dequant + IDCT)
    results["luma_residual"] = grade_luma_residual(ratchet)
    r = results["luma_residual"]
    print(
        f"[RTL] luma_residual: status={r['status']} "
        f"tests={r.get('tests_exact', '?')} "
        f"nontrivial={r.get('nontrivial', '?')} "
        f"coverage={r.get('pixels_covered', 0)}/{ratchet['aggregate']['total_luma_pixels']}px"
    )
    failures.extend(check_monotonic("luma_residual", r, ratchet))

    # Stage 2: Luma reconstruction (module-level)
    results["luma_reconstruction"] = grade_luma_reconstruction(ratchet)
    r = results["luma_reconstruction"]
    print(
        f"[RTL] luma_reconstruction: status={r['status']} "
        f"mb_exact={r.get('mb_exact', 0)}/{r.get('mb_total', 0)} "
        f"recon_differed={r.get('recon_differed_from_pred', 0)} "
        f"coverage={r.get('pixels_covered', 0)}/{ratchet['aggregate']['total_luma_pixels']}px "
        f"(MODULE-LEVEL, not pipeline)"
    )
    failures.extend(check_monotonic("luma_reconstruction", r, ratchet))

    # Unimplemented stages — report honestly
    unimplemented = [
        "luma_prediction",
        "chroma_residual",
        "chroma_dc_hadamard",
        "chroma_prediction",
        "chroma_reconstruction",
        "deblock",
    ]
    for stage in unimplemented:
        results[stage] = grade_unimplemented_stage(stage, ratchet)
        r = results[stage]
        print(
            f"[RTL] {stage}: status=NOT_IMPLEMENTED "
            f"coverage=0/{ratchet['aggregate'].get('total_luma_pixels', '?')}px"
        )
        failures.extend(check_monotonic(stage, r, ratchet))

    # Summary
    print("=" * 72)
    total_luma_px = ratchet["aggregate"]["total_luma_pixels"]
    total_chroma_u = ratchet["aggregate"]["total_chroma_u_pixels"]
    total_chroma_v = ratchet["aggregate"]["total_chroma_v_pixels"]
    luma_covered = results["luma_reconstruction"].get("pixels_covered", 0)
    chroma_u_covered = 0  # not implemented
    chroma_v_covered = 0  # not implemented

    print(f"[RTL] AGGREGATE COVERAGE:")
    print(f"  Y:  {luma_covered}/{total_luma_px} pixels ({100*luma_covered/total_luma_px:.1f}%)")
    print(f"  U:  {chroma_u_covered}/{total_chroma_u} pixels ({100*chroma_u_covered/total_chroma_u:.1f}%)")
    print(f"  V:  {chroma_v_covered}/{total_chroma_v} pixels ({100*chroma_v_covered/total_chroma_v:.1f}%)")
    print(f"  Pipeline-level (integrated): 16/{total_luma_px} pixels ({100*16/total_luma_px:.3f}%)")
    print(f"  Module-level (individual RTL modules): {luma_covered}/{total_luma_px} pixels")

    if failures:
        print(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            print(f"  {f}")
        print(f"\nRTL DATAPATH RATCHET: FAIL — {len(failures)} regression(s)")
        rc = 1
    else:
        print(f"\nRTL DATAPATH RATCHET: PASS — no regressions, coverage monotonic")
        rc = 0

    # Write JSON output
    if args.output:
        output = {
            "format": "misterplex.p3.rtl_datapath_score.v1",
            "verification_target": "RTL",
            "stages": results,
            "aggregate": {
                "luma_pixels_covered": luma_covered,
                "luma_pixels_total": total_luma_px,
                "chroma_u_pixels_covered": chroma_u_covered,
                "chroma_u_pixels_total": total_chroma_u,
                "chroma_v_pixels_covered": chroma_v_covered,
                "chroma_v_pixels_total": total_chroma_v,
                "pipeline_level_pixels": 16,
            },
            "ratchet_failures": failures,
            "pass": rc == 0,
        }
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
            f.write("\n")

    return rc


if __name__ == "__main__":
    sys.exit(main())
