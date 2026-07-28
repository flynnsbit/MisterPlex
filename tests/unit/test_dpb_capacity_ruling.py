#!/usr/bin/env python3
"""Encodes the DPB capacity ruling as arithmetic that cannot drift.

The claim under test: at the target geometry the decoded picture buffer cannot
live in on-chip block RAM, with or without retiring decode_stub, so the picture
store must be external. This is not an estimate — it is derived from geometry
and from device totals in a fit report bound to a bitstream md5.

Calibration matters as much as the verdict: the same model must reproduce the
2,097,152 bits Quartus really allocated for decode_stub's picture store. A
capacity model that cannot predict a measured allocation is not evidence.
"""
from __future__ import annotations

import hashlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts" / "check_dpb_capacity.py"

# Device totals copied from the fit report bound to the resident bitstream
# fb4bad849ad2db782a5004ce5a3471ce (w-fit-o5's wfit-hour27-bdiag-b slot).
DEVICE_BLOCK_BITS = 5_662_720
USED_BLOCK_BITS = 2_970_061
# decode_stub's altsyncram:dpb_mem_rtl_0 as measured by w-fit-o5.
STUB_PICTURE_STORE_BITS = 2_097_152

REPORT_TEMPLATE = """\
Fitter Resource Usage Summary
; Total block memory bits         ; {used:,} / {total:,} ( 52 % )              ;
; Total RAM Blocks                ; 453 / 553 ( 82 % )                          ;
"""


def run(args: list[str]) -> tuple[int, str]:
    proc = subprocess.run([sys.executable, str(CHECKER)] + args,
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def field(out: str, name: str) -> int:
    match = re.search(rf"\b{name}=(\d+)", out)
    if match is None:
        raise AssertionError(f"no {name}= in output:\n{out}")
    return int(match.group(1))


def main() -> int:
    print("Scope: DPB capacity arithmetic against a bitstream-bound fit report. "
          "Checks the model reproduces a measured allocation, that the verdict "
          "flips with geometry, and that an unbound report never passes. Does "
          "not measure logic, DSP, bandwidth, or latency.")

    with tempfile.TemporaryDirectory() as tmp:
        out_dir = Path(tmp)
        report = out_dir / "Plex.fit.rpt"
        report.write_text(REPORT_TEMPLATE.format(
            used=USED_BLOCK_BITS, total=DEVICE_BLOCK_BITS))
        rbf = out_dir / "Plex.rbf"
        rbf.write_bytes(b"fixture bitstream, not a real RBF")
        md5 = hashlib.md5(rbf.read_bytes()).hexdigest()

        base = ["--fit-report", str(report), "--expect-rbf-md5", md5]

        # 1. Calibration: predict what Quartus actually allocated for the stub.
        rc, out = run(base + ["--width", "320", "--height", "240",
                              "--ref-frames", "1", "--label", "stub"])
        fitted = field(out, "fitted_bits_pow2_depth")
        if fitted != STUB_PICTURE_STORE_BITS:
            print(f"FAIL calibration: model says {fitted} bits for decode_stub's "
                  f"picture store, Quartus allocated {STUB_PICTURE_STORE_BITS}",
                  file=sys.stderr)
            return 1
        stub_rc = rc
        print(f"OK calibration: model reproduces the measured stub allocation "
              f"{fitted} bits; verdict rc={stub_rc}")

        # 2. Product geometry, nothing freed.
        rc_product, out_product = run(base + [
            "--width", "624", "--height", "480", "--ref-frames", "1",
            "--label", "product"])
        if rc_product != 1:
            print(f"FAIL: product geometry did not report EXCEEDS (rc={rc_product})\n"
                  f"{out_product}", file=sys.stderr)
            return 1

        # 3. Anti-vacuity: geometry is the only thing varied between 1 and 2, so
        #    the verdict must actually differ. Otherwise this proves nothing.
        if rc_product == stub_rc:
            print(f"FAIL vacuous: verdict rc={rc_product} is identical for stub "
                  f"and product geometry, so the comparison does not test "
                  f"geometry at all", file=sys.stderr)
            return 1
        print(f"OK anti-vacuity: verdict flips with geometry alone "
              f"(320x240 rc={stub_rc}, 624x480 rc={rc_product})")

        # 4. Retiring decode_stub does not rescue it.
        rc_freed, out_freed = run(base + [
            "--width", "624", "--height", "480", "--ref-frames", "1",
            "--assume-freed-bits", str(STUB_PICTURE_STORE_BITS),
            "--label", "product_after_stub_retirement"])
        if rc_freed != 1:
            print(f"FAIL: product geometry fits after freeing the stub "
                  f"(rc={rc_freed}); the ruling this test encodes is wrong\n"
                  f"{out_freed}", file=sys.stderr)
            return 1
        short = re.search(r"short by (\d+) bits", out_freed)
        print(f"OK ruling: 624x480 exceeds on-chip capacity even with all "
              f"{STUB_PICTURE_STORE_BITS} stub bits released, short by "
              f"{short.group(1) if short else '?'} bits")

        # 5. One picture alone is already most of the device.
        one_picture = field(out_product, "picture_bytes") * 8
        print(f"OK scale: one reference picture is {one_picture} bits = "
              f"{100.0 * one_picture / DEVICE_BLOCK_BITS:.1f}% of all block "
              f"memory on the device")

        # 6. An unbound report must never pass.
        rc_unbound, out_unbound = run([
            "--fit-report", str(report), "--width", "624", "--height", "480"])
        if rc_unbound != 2 or "UNBOUND" not in out_unbound:
            print(f"FAIL: report without --expect-rbf-md5 did not return "
                  f"UNBOUND rc=2 (rc={rc_unbound})\n{out_unbound}", file=sys.stderr)
            return 1

        rc_wrong, out_wrong = run([
            "--fit-report", str(report), "--expect-rbf-md5", "deadbeef",
            "--width", "624", "--height", "480"])
        if rc_wrong != 2 or "UNBOUND" not in out_wrong:
            print(f"FAIL: wrong md5 did not return UNBOUND rc=2 "
                  f"(rc={rc_wrong})\n{out_wrong}", file=sys.stderr)
            return 1

        rc_missing, _ = run(base[:1] + [str(out_dir / "absent.rpt")] + base[2:] +
                            ["--width", "624", "--height", "480"])
        if rc_missing != 2:
            print(f"FAIL: missing report did not return rc=2 (rc={rc_missing})",
                  file=sys.stderr)
            return 1
        print("OK binding: absent md5, wrong md5 and missing report all rc=2, "
              "never a pass")

    print("DPB_CAPACITY_RULING_OK on-chip picture store is arithmetically "
          "impossible at 624x480; the store must be external (DDR)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
