#!/usr/bin/env python3
"""Gate multi-pixel present clk_sys arithmetic (no fit, no device).

Verifies assets/multi_pixel_present_contract.json against pure arithmetic and
parent expectations. Optionally checks RTL modules exist and product macro is OFF.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def die(msg: str, rc: int = 1) -> None:
    print(f"MULTI_PIXEL_PRESENT_REJECTED(exit={rc}): {msg}", file=sys.stderr)
    raise SystemExit(rc)


def load_contract(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"{path}: {exc}", 2)
    if not isinstance(data, dict):
        die(f"{path} not an object", 2)
    return data


def mode_mpix(mode: dict) -> float:
    kind = mode["kind"]
    fps = float(mode["fps"])
    if kind == "content":
        return float(mode["w"]) * float(mode["h"]) * fps / 1e6
    if kind in ("cea", "template"):
        return float(mode["h_total"]) * float(mode["v_total"]) * fps / 1e6
    die(f"unknown mode kind {kind!r}", 2)
    return 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--contract",
        type=Path,
        default=Path("assets/multi_pixel_present_contract.json"),
    )
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument(
        "--require-rtl",
        action="store_true",
        help="Require listed RTL modules present and PRESENT_MULTI_PIXEL not forced on in Plex.sv",
    )
    args = ap.parse_args()
    root: Path = args.root.resolve()
    contract = load_contract((root / args.contract).resolve() if not args.contract.is_absolute() else args.contract)

    tol = float(contract.get("tolerance_mhz", 0.001))
    fmax = contract["measured_fmax_mhz"]
    ship = float(fmax["shipping_pll_clk_sys"])
    stub = float(fmax["stub_in_8fdf440f"])
    nostub = float(fmax["nostub_c74c6863"])

    modes = contract["modes"]
    expected = contract["expected_need_mhz"]
    fails: list[str] = []

    print("MULTI_PIXEL_ARITH_BEGIN")
    print(f"Fmax ship={ship} stub={stub} nostub={nostub} (from contract; STA not re-parsed here)")

    for name, mode in modes.items():
        mpix = mode_mpix(mode)
        exp_map = expected.get(name)
        if not isinstance(exp_map, dict):
            fails.append(f"missing expected_need_mhz.{name}")
            continue
        for ppc_s, exp in exp_map.items():
            ppc = int(ppc_s)
            need = mpix / ppc
            exp_f = float(exp)
            ok = abs(need - exp_f) <= tol
            mark_ship = "OK" if need <= ship + 1e-12 else "FAIL"
            mark_stub = "OK" if need <= stub + 1e-12 else "FAIL"
            mark_ns = "OK" if need <= nostub + 1e-12 else "FAIL"
            status = "PASS" if ok else "ARITH_MISMATCH"
            print(
                f"  {name:16s} ppc={ppc} mpix={mpix:.4f} need={need:.4f} "
                f"exp={exp_f:.4f} {status} ship={mark_ship} stub={mark_stub} nostub={mark_ns}"
            )
            if not ok:
                fails.append(f"{name} ppc={ppc}: need {need} != exp {exp_f}")

    # Parent expectation band
    pe = contract.get("parent_expectation", {})
    c24_2 = float(expected["content_720p24"]["2"])
    cea24_2 = float(expected["cea_720p24"]["2"])
    lo, hi = pe.get("ppc2_720p24_mhz_range", [11.0, 15.0])
    if not (lo <= c24_2 <= hi and lo <= cea24_2 <= hi):
        fails.append(
            f"ppc2 720p24 content={c24_2} cea={cea24_2} not both in [{lo},{hi}]"
        )
    else:
        print(f"PARENT_EXPECT ppc2_720p24 content={c24_2:.3f} cea={cea24_2:.3f} in [{lo},{hi}] OK")

    cea60_2 = float(expected["cea_720p60"]["2"])
    near = float(pe.get("ppc2_720p60_mhz_near", 37.0))
    if abs(cea60_2 - near) > 0.2:
        fails.append(f"cea_720p60 ppc2 {cea60_2} not near {near}")
    else:
        print(f"PARENT_EXPECT ppc2_cea720p60={cea60_2:.3f} near {near} OK")

    # Hard programme verdicts encoded in contract
    verdicts = contract.get("verdicts_vs_fmax", {})
    checks = [
        ("content_720p24_ppc1_ship20", float(expected["content_720p24"]["1"]) <= ship, "FAIL"),
        ("content_720p24_ppc2_ship20", float(expected["content_720p24"]["2"]) <= ship, "OK"),
        ("cea_720p60_ppc2_nostub", float(expected["cea_720p60"]["2"]) <= nostub, "FAIL"),
        ("cea_720p60_ppc4_ship20", float(expected["cea_720p60"]["4"]) <= ship, "OK"),
    ]
    for key, predicate_ok, want_label in checks:
        want = verdicts.get(key)
        # predicate_ok True means frequency fits → label OK
        got = "OK" if predicate_ok else "FAIL"
        if want is not None and got != want:
            fails.append(f"verdict {key}: got {got} want {want}")
        print(f"VERDICT {key}={got} (contract want={want})")


    # Source-vs-output class: identity store map is not 720p-source.
    wsi = contract.get("w_scaler_interface", {})
    if wsi.get("content_geometry") == "1280x720":
        fails.append(
            "w_scaler_interface.content_geometry must not be bare 1280x720 "
            "(conflates glass with source); use glass_geometry + source_geometry_product"
        )
    if wsi.get("glass_geometry") != "1280x720":
        fails.append("glass_geometry must be 1280x720 (output raster)")
    if wsi.get("source_geometry_product") != "960x540":
        fails.append("source_geometry_product must record parent product 960x540")
    if int(wsi.get("source_display_h_product", -1)) != 540:
        fails.append("source_display_h_product must be 540 (libav/SPS crop; ARM bank)")
    if int(wsi.get("source_coded_h_bitstream", -1)) != 544:
        fails.append("source_coded_h_bitstream must be 544 (SPS; fabric/ring only)")
    if not wsi.get("identity_store_map_requires_frame_eq_glass", False):
        fails.append("identity_store_map_requires_frame_eq_glass must be true")
    marker = wsi.get("identity_guard_marker", "MP_IDENTITY_FRAME_EQ_GLASS")
    pc_path = root / "fpga/Plex_MiSTer/rtl/present_core.sv"
    pct = pc_path.read_text(encoding="utf-8", errors="ignore") if pc_path.is_file() else ""
    if marker not in pct:
        fails.append(f"present_core.sv missing identity guard marker {marker}")
    else:
        print(f"GEOM_OK identity guard marker {marker}")
    sweep = root / ".agent-work/w-clock/SOURCE_VS_OUTPUT_GEOM_SWEEP.md"
    if not sweep.is_file():
        fails.append("missing SOURCE_VS_OUTPUT_GEOM_SWEEP.md")
    else:
        print("GEOM_OK sweep doc present")
    # Rate-match must stay geometry-free (no FRAME/H_DE ports)
    rm = (root / "fpga/Plex_MiSTer/rtl/present_pix_rate_match.sv").read_text(encoding="utf-8", errors="ignore")
    if "FRAME_W" in rm or "H_DE" in rm or "1280" in rm:
        fails.append("present_pix_rate_match must stay clock-only (no geometry keys)")
    else:
        print("GEOM_OK rate_match geometry-free")

    if args.require_rtl:
        rtl = contract.get("rtl", {})
        def active_define(src: str, name: str) -> bool:
            """True if `define NAME appears outside // and /* */ comments."""
            no_block = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
            for line in no_block.splitlines():
                code = line.split("//", 1)[0]
                if re.search(rf"`define\s+{re.escape(name)}\b", code):
                    return True
            return False

        for rel in rtl.get("modules", []):
            p = root / rel
            if not p.is_file():
                fails.append(f"missing RTL {rel}")
                continue
            body = p.read_text(encoding="utf-8", errors="ignore")
            if "PRESENT_MULTI_PIXEL" not in body and "MULTI_PIXEL" not in body:
                fails.append(f"{rel} missing PRESENT_MULTI_PIXEL/MULTI_PIXEL documentation mark")
            else:
                print(f"RTL_OK {rel}")

        plex = root / "fpga/Plex_MiSTer/Plex.sv"
        text = plex.read_text(encoding="utf-8", errors="ignore") if plex.is_file() else ""
        # Refuse accidental product enable (`ifdef is OK; bare `define is not).
        if active_define(text, "PRESENT_MULTI_PIXEL"):
            fails.append("Plex.sv defines PRESENT_MULTI_PIXEL — must default OFF")
        pc = root / "fpga/Plex_MiSTer/rtl/present_core.sv"
        pct = pc.read_text(encoding="utf-8", errors="ignore") if pc.is_file() else ""
        if active_define(pct, "PRESENT_MULTI_PIXEL"):
            fails.append("present_core.sv defines PRESENT_MULTI_PIXEL — must default OFF")

    print("MULTI_PIXEL_ARITH_END")
    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        die(f"{len(fails)} check(s) failed", 1)
    print("PASS multi_pixel_present_contract")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
