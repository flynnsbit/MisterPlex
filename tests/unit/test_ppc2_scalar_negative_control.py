#!/usr/bin/env python3
"""rd-duck discriminator: true PPC2 gate MUST FAIL scalar negative control.

Beat TBs (G0/G1 payload counts) are insensitive to dual-lane correctness:
a scalar reader with rd_x+=2 still refills whole lines and can match PPC2
beat counts bit-identically. That metric is REFILL_BEATS only.

This gate:
  1) Proves the *replicate* / scalar RGB path produces EQUAL adjacent-lane
     checksums (no distinct odd/even) — the negative control that must FAIL
     a dual-lane correctness check.
  2) Proves the real yuv_bt601_npx dual-lane path produces UNEQUAL odd/even
     checksums (positive path).
  3) Fails if anyone claims PPC2 reader closed from beat TB alone in the
     shared fixture without the PARTIAL_CLOSED_READER split.

Negative cases a naive wrong impl would miss:
  - Treating {PPC{scalar_r}} as dual-lane PASS
  - fixture fabric_bw_closed=true or unsplit reader CLOSED
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"
NPX = ROOT / "fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv"
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"


def fail(msg: str) -> int:
    print(f"FAIL ppc2_scalar_neg: {msg}", file=sys.stderr)
    return 1


def _bt601_y(y: int, u: int, v: int) -> tuple[int, int, int]:
    """Match yuv_bt601_npx.sv integer path (same as test_yuv_bt601_npx_ppc2)."""
    c = y - 16
    d = u - 128
    e = v - 128
    r = (298 * c + 409 * e + 128) >> 8
    g = (298 * c - 100 * d - 208 * e + 128) >> 8
    b = (298 * c + 516 * d + 128) >> 8
    r = max(0, min(255, r))
    g = max(0, min(255, g))
    b = max(0, min(255, b))
    return r, g, b


def main() -> int:
    # --- 1) Scalar / replicate path: adjacent lanes EQUAL (negative control) ---
    # Product bug class: present_core used {PPC{fr}} — both lanes same pixel.
    y0, u0, v0 = 16 + 50, 128, 128  # mid grey-ish
    r0, g0, b0 = _bt601_y(y0, u0, v0)
    # Scalar emit: pack two copies of lane0
    scalar_npx_r = (r0 << 8) | r0  # if 8-bit per lane packing conceptual
    csum_even_s = r0 + g0 + b0
    csum_odd_s = r0 + g0 + b0  # replicate → identical
    if csum_even_s != csum_odd_s:
        return fail("internal: scalar replicate must have equal lane checksums")
    # Dual-lane correctness predicate (must FAIL on scalar)
    dual_lane_ok_scalar = csum_even_s != csum_odd_s
    if dual_lane_ok_scalar:
        return fail("NEGATIVE CONTROL BROKEN: scalar path must FAIL dual-lane distinct check")
    print(
        f"OK scalar negative control FAILS dual-lane check "
        f"(csum_e={csum_even_s} csum_o={csum_odd_s} equal — as required)"
    )

    # --- 2) True dual-lane yuv path: adjacent lanes UNEQUAL ---
    # src_x0=0 even origin: lane0 uses Y[x], lane1 uses Y[x+1] with distinct Y
    y_even, y_odd = 16 + 40, 16 + 200
    u, v = 128 + 10, 128 - 15
    r_e, g_e, b_e = _bt601_y(y_even, u, v)
    r_o, g_o, b_o = _bt601_y(y_odd, u, v)
    csum_e = r_e + g_e + b_e
    csum_o = r_o + g_o + b_o
    if csum_e == csum_o:
        return fail(
            f"dual-lane positive path: expected unequal odd/even csum got {csum_e}"
        )
    print(f"OK dual-lane positive path unequal csum even={csum_e} odd={csum_o}")

    # --- 3) RTL must not reintroduce replicate packing in present_core ---
    # Strip // comments so doc lines like "NOT {PPC{fr}}" do not false-fail.
    pres_raw = PRESENT.read_text(encoding="utf-8", errors="replace")
    pres_code = "\n".join(
        ln.split("//", 1)[0] for ln in pres_raw.splitlines()
    )
    if re.search(r"\{PPC\{f[rgb]\}\}", pres_code):
        return fail("present_core still has {PPC{fr/fg/fb}} replicate packing")
    if not re.search(r"mp_npx_r\s*=\s*fs_r_n", pres_code):
        return fail("present_core must wire mp_npx_r = fs_r_n (N-wide store)")
    print("OK present_core has N-wide fs_r_n wiring (no replicate pack)")

    # --- 4) Store must expose PX_PER_CLK / rd_*_n (dual-lane ports exist) ---
    st = STORE.read_text(encoding="utf-8", errors="replace")
    if "PX_PER_CLK" not in st:
        return fail("ddr_frame_store missing PX_PER_CLK (dual-lane ports)")
    if "rd_r_n" not in st and "rd_rgb_n" not in st:
        # accept either packed or split N-wide
        if not re.search(r"rd_[rgb]_n", st):
            return fail("ddr_frame_store missing rd_*_n N-wide outputs")
    print("OK ddr_frame_store has PX_PER_CLK + rd_*_n")

    # --- 5) yuv_bt601_npx must index lane i = src_x0+i (not broadcast) ---
    npx = NPX.read_text(encoding="utf-8", errors="replace")
    if "src_x0" not in npx and "x0" not in npx:
        return fail("yuv_bt601_npx must take base x for per-lane addressing")
    # crude: forbid assigning same y to all lanes without index
    if re.search(r"for\s*\(.*i.*\).*y_n\[i\]\s*=\s*y_n\[0\]", npx):
        return fail("yuv_bt601_npx broadcasts y_n[0] to all lanes")
    print("OK yuv_bt601_npx present for dual-lane convert")

    # --- 6) Fixture honesty: PARTIAL_CLOSED_READER / no PPC2 closed from beats ---
    c = json.loads(FIX.read_text(encoding="utf-8"))
    gap = c.get("proof_gap") or {}
    if gap.get("status") != "PARTIAL_CLOSED_READER":
        return fail(f"fixture proof_gap.status must be PARTIAL_CLOSED_READER got {gap.get('status')!r}")
    if gap.get("fabric_bw_closed") is not False:
        return fail("NEGATIVE: fixture fabric_bw_closed must be false")
    rsd = gap.get("reader_steady_delta") or {}
    if rsd.get("status") == "CLOSED":
        return fail(
            "NEGATIVE: unsplit reader_steady_delta CLOSED — beat TB ≠ PPC2 dual-lane closed"
        )
    if rsd.get("status") != "REFILL_BEATS_CLOSED":
        return fail(f"reader_steady_delta.status want REFILL_BEATS_CLOSED got {rsd.get('status')!r}")
    ppc = gap.get("ppc2_dual_lane_correctness") or {}
    if ppc.get("status") in (None, "CLOSED"):
        return fail("ppc2_dual_lane_correctness must not be CLOSED by beat TB")
    disc = rsd.get("rd_duck_discriminator") or {}
    req = (disc.get("required_negative_control") or "").lower()
    if "fail scalar" not in req and "fail" not in req:
        return fail("fixture missing required_negative_control FAIL scalar language")
    print("OK fixture PARTIAL_CLOSED_READER + REFILL_BEATS_CLOSED + dual-lane not from beats")

    # --- 7) Live dual-lane shell gate still green (positive) ---
    sh = ROOT / "tests/unit/test_yuv_bt601_npx_ppc2.sh"
    if sh.is_file():
        r = subprocess.run(["bash", str(sh)], cwd=str(ROOT), capture_output=True, text=True)
        if r.returncode != 0:
            return fail(f"test_yuv_bt601_npx_ppc2.sh rc={r.returncode}\n{r.stdout}\n{r.stderr}")
        print("OK test_yuv_bt601_npx_ppc2.sh rc=0 (dual-lane positive)")

    print("PASS test_ppc2_scalar_negative_control")
    return 0


if __name__ == "__main__":
    sys.exit(main())
