#!/usr/bin/env python3
import subprocess
import sys
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERILATOR = Path.home() / ".local/oss-cad-suite-20260726/bin/verilator"
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
TB = ROOT / "tests/unit/rtl/p3_intra_frame_tb.sv"
CPP = ROOT / "tests/unit/test_p3_intra_frame_verilator.cpp"


def run(cmd, *, expect_success=True):
    proc = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    sys.stdout.write(proc.stdout)
    if expect_success and proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc.returncode


def source_fingerprint(negative: bool) -> str:
    h = hashlib.sha256()
    h.update(b"negative" if negative else b"positive")
    for path in [RTL / "h264_iq_idct_4x4.sv", RTL / "h264_intra_pred.sv", TB, CPP]:
        h.update(path.read_bytes())
    return h.hexdigest()[:12]


def build_and_run(name: str, negative: bool) -> int:
    build_dir = ROOT / f"build/obj_{name}_{source_fingerprint(negative)}"
    build_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(VERILATOR), "--cc", "--exe", "--build",
        "--top-module", "p3_intra_frame_tb",
        "--Mdir", str(build_dir),
        "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
        "--CFLAGS", f"-std=c++17 -O2 -I{ROOT}/host",
    ]
    if negative:
        cmd.append("-DP3_INTRA_FRAME_RARE_NEGATIVE_TEST")
    cmd += [
        str(RTL / "h264_iq_idct_4x4.sv"),
        str(RTL / "h264_intra_pred.sv"),
        str(TB),
        str(CPP),
    ]
    run(cmd)
    return run([str(build_dir / "Vp3_intra_frame_tb")], expect_success=False)


def main() -> int:
    if not VERILATOR.exists():
        print(f"SKIP P3_INTRA_FRAME_VERILATOR: Verilator not found at {VERILATOR}; frame-wide RTL behavioural test NOT run")
        return 0
    neg_rc = build_and_run("p3_intra_frame_neg", True)
    if neg_rc == 0:
        print("P3 intra frame-wide negative-direction check FAILED: DDR-mode RTL perturbation still passed")
        return 1
    print("P3 intra frame-wide negative-direction check PASS: rare DDR-mode RTL perturbation was detected (red path).")
    pos_rc = build_and_run("p3_intra_frame", False)
    if pos_rc != 0:
        return pos_rc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
