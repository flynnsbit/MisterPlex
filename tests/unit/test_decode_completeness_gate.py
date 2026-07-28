#!/usr/bin/env python3
"""Unit coverage for the product decode completeness gate."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "check_decode_completeness.py"


def run_gate(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GATE), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=60,
    )


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def main() -> int:
    current = run_gate()
    combined = current.stdout + current.stderr
    require(current.returncode == 1, f"current incomplete decoder must hard-fail rc=1, got {current.returncode}\n{combined}")
    require(combined.startswith("Scope: decode-completeness"), "gate must print Scope first")
    for cfg in ("DECODE_REAL_INTRA=0", "DECODE_REAL_INTRA=1"):
        require(f"DECODE_COMPLETENESS_CONFIG config={cfg} status=FAIL" in combined,
                f"missing current FAIL baseline for {cfg}\n{combined}")
        require(f"DECODE_TOPOLOGY config={cfg} status=FAIL" in combined,
                f"missing current topology FAIL baseline for {cfg}\n{combined}")
    require("DECODE_LINEAGE_COUNT count=4" in combined, f"lineage count missing\n{combined}")
    require("root=decode_stub classification=product:DECODE_REAL_INTRA=0" in combined,
            "decode_stub lineage classification missing")
    require("root=h264_decode_top classification=product:DECODE_REAL_INTRA=1" in combined,
            "h264_decode_top lineage classification missing")
    require("root=h264_decode_core classification=dead/staged" in combined,
            "h264_decode_core dead/staged lineage classification missing")
    require("root=h264_decode_skeleton classification=dead/resource-estimation" in combined,
            "h264_decode_skeleton dead/resource lineage classification missing")
    print("PASS current product decode configs hard-fail with four lineages reported")

    synthetic = run_gate("--synthetic-complete")
    require(synthetic.returncode == 0 and "DECODE_COMPLETENESS_OK synthetic complete graph" in synthetic.stdout,
            f"synthetic complete graph did not pass\nstdout={synthetic.stdout}\nstderr={synthetic.stderr}")
    print("PASS synthetic complete graph satisfies every category")

    red = run_gate("--synthetic-complete", "--synthetic-drop-category", "mv_prediction")
    red_combined = red.stdout + red.stderr
    require(red.returncode == 1 and "category=mv_prediction status=FAIL" in red_combined,
            f"synthetic category removal did not go red\nstdout={red.stdout}\nstderr={red.stderr}")
    print("PASS synthetic missing-category mutation goes red")

    bad_topology = run_gate("--synthetic-complete", "--synthetic-bad-topology")
    bad_topology_combined = bad_topology.stdout + bad_topology.stderr
    require(
        bad_topology.returncode == 1
        and "DECODE_TOPOLOGY config=synthetic status=FAIL" in bad_topology_combined
        and "retired_decoder_reachable=decode_stub" in bad_topology_combined,
        "synthetic retired-decoder topology did not go red\n"
        f"stdout={bad_topology.stdout}\nstderr={bad_topology.stderr}",
    )
    print("PASS synthetic retired-decoder topology mutation goes red")

    dead = run_gate("--synthetic-complete", "--synthetic-dead-outputs")
    dead_combined = dead.stdout + dead.stderr
    require(
        dead.returncode == 1
        and "DECODE_OUTPUT_SINK config=synthetic" in dead_combined
        and "status=FAIL" in dead_combined
        and "all_outputs_dead_end" in dead_combined
        and "required_output_not_live=dpb_wr_en:dead_end" in dead_combined,
        "synthetic dead-output decoder did not go red\n"
        f"stdout={dead.stdout}\nstderr={dead.stderr}",
    )
    live = run_gate("--synthetic-complete")
    require(
        "DECODE_OUTPUT_SINK config=synthetic decoder=h264_decode_core parent=stream_path status=PASS" in live.stdout
        and "live=4 dead_end=0" in live.stdout,
        f"synthetic live-output decoder did not pass the sink check\n{live.stdout}",
    )
    print("PASS anti-prune-only decoder outputs go red, real sinks stay green")

    require(
        "scope=product_decoder_subtree" in combined,
        f"capability scope must be the product decoder subtree, not the whole product graph\n{combined}",
    )
    require(
        "donated_by_non_product_lineage=" in combined,
        f"capability lines must report modules donated by non-product lineages\n{combined}",
    )
    print("PASS capabilities are scored inside the product decoder subtree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
