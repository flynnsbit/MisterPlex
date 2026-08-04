#!/usr/bin/env python3
"""Host-side glass vsync rate from product PLXD glass field (modular12 Δ).

Reads / scores PLXD[47:36] glass_vsync_count[11:0] (bank_vsync_count LSBs).
MS2109 /dev/video0 reclocks — grabber PTS cannot RATE_PASS glass Hz.
Use modular Δ-count / wall_s over ≥2 s.

Product map (from host/libmisterplex/ddr_frame_layout.hpp + mailbox_abi):
  doorbell 0x302FF000 → PLXD 0x302FF128 (doorbell + 0x128)

Live RBF 75065b0c lacks bank_vsync pack + schedule reg → glass field
zero/stale (STALE_OR_ZERO). After cutb-sched-reg RBF with glass pack:
expect ~24.242 Hz at clk_pix=30.000 MHz (30e6/(1650*750)), NOT 31.25 grabber.

Modes (no fake green):
  --self-test     pure modular math (no device). Exit 0 only if asserts hold.
  --from-samples  offline series: mono_s glass_u12  (or plxd_hi_hex)
  --print-addrs   resolve product PLXD from layout SoT and exit
  --live          PARENT-ONLY device poll recipe; refuses without --i-am-parent

Exit: 0 measured/self-test OK, 77 UNSCORED/STALE, 2 usage, 1 fail.
Soft-skip / STALE_OR_ZERO / UNSCORED ≠ PASS.
"""
from __future__ import annotations

import argparse
import math
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAYOUT_HPP = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"
ABI_HPP = ROOT / "host/libmisterplex/mailbox_abi_spec.hpp"

RC_OK = 0
RC_FAIL = 1
RC_USAGE = 2
RC_UNSCORED = 77

MOD = 4096
MASK = 0x0FFF
MIN_DT_S = 2.0
# Ideal glass @ 30 MHz clk_pix pack — document only, never hard PASS.
IDEAL_GLASS_HZ = 30_000_000.0 / (1650.0 * 750.0)  # 24.2424...


def modular12_delta(c0: int, c1: int) -> int:
    """Forward modular distance on free-running 12-bit counter."""
    return (int(c1) - int(c0)) & MASK


def glass_from_plxd_hi(hi: int) -> int:
    """PLXD upper word bits [15:4] = glass_vsync[11:0] (bit 4 of hi word)."""
    return (int(hi) >> 4) & MASK


def glass_rate_from_pair(
    c0: int, c1: int, dt_s: float, min_dt_s: float = MIN_DT_S
) -> dict:
    c0m = int(c0) & MASK
    c1m = int(c1) & MASK
    delta = modular12_delta(c0m, c1m)
    out = {
        "c0": c0m,
        "c1": c1m,
        "delta": delta,
        "dt_s": float(dt_s),
        "rate_hz": None,
        "ok": False,
        "verdict": "UNSCORED",
        "note": "",
    }
    if not (math.isfinite(dt_s) and dt_s > 0.0):
        out["verdict"] = "BAD_DT"
        out["note"] = "dt_s must be finite and > 0"
        return out
    if not (math.isfinite(min_dt_s) and min_dt_s > 0.0):
        out["verdict"] = "BAD_DT"
        out["note"] = "min_dt_s must be finite and > 0"
        return out
    if dt_s + 1e-15 < min_dt_s:
        out["verdict"] = "UNSCORED"
        out["note"] = "wall window shorter than min_dt_s (need >=2s)"
        out["rate_hz"] = delta / dt_s
        return out
    out["rate_hz"] = delta / dt_s
    if delta == 0:
        out["verdict"] = "STALE_OR_ZERO"
        out["note"] = (
            "glass_vsync did not advance; live 75065b0c (no pack) class — not PASS"
        )
        return out
    out["verdict"] = "MEASURED"
    out["ok"] = True
    out["note"] = "rate_hz = modular12_delta / wall_s; not MS2109 grabber PTS"
    return out


def resolve_product_plxd() -> tuple[int, int, int]:
    """Return (doorbell, plxd_lo, plxd_hi_word_addr) from layout SoT."""
    text = LAYOUT_HPP.read_text(encoding="utf-8", errors="replace")
    m = re.search(
        r"kPlex720pYuv420pDoorbellPhys\s*=\s*(0x[0-9A-Fa-f]+)u",
        text,
    )
    if not m:
        raise RuntimeError(f"doorbell missing from {LAYOUT_HPP}")
    doorbell = int(m.group(1), 16)
    # Offset 0x128 pinned in mailbox_abi (not re-parsed to avoid dual SoT).
    off = 0x128
    plxd = doorbell + off
    return doorbell, plxd, plxd + 4


def self_test() -> int:
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL {msg}", file=sys.stderr)
            fails += 1
        else:
            print(f"OK {msg}")

    check(modular12_delta(0, 0) == 0, "delta 0→0 = 0")
    check(modular12_delta(100, 148) == 48, "delta 100→148 = 48")
    check(modular12_delta(4090, 5) == 11, "wrap 4090→5 = 11")
    check(modular12_delta(0xFFF, 0) == 1, "wrap FFF→0 = 1")
    # NEGATIVE: naive uint16 wrap is not modular12
    naive = (5 - 4090) & 0xFFFF
    check(naive != 11, "NEG: uint16 wrap != modular12")
    check(modular12_delta(4090, 5) != naive, "NEG twin modular12 != naive")

    check(glass_from_plxd_hi(0x00070005) == 0, "hi glass extract 0")
    check(glass_from_plxd_hi(0x12340AB8) == 0x0AB, "hi glass extract 0x0AB")
    check(glass_from_plxd_hi(0xFFFFFFF2) == 0xFFF, "hi glass extract 0xFFF")

    r = glass_rate_from_pair(100, 148, 2.0)
    check(r["ok"] and abs(r["rate_hz"] - 24.0) < 1e-12, "rate 48/2s = 24 Hz MEASURED")
    r = glass_rate_from_pair(4090, 5, 2.0)
    check(r["ok"] and abs(r["rate_hz"] - 5.5) < 1e-12, "wrap rate 11/2s = 5.5 Hz")
    r = glass_rate_from_pair(0, 0, 2.5)
    check(
        (not r["ok"]) and r["verdict"] == "STALE_OR_ZERO",
        "zero delta over 2.5s = STALE_OR_ZERO (not PASS)",
    )
    r = glass_rate_from_pair(0, 50, 1.0)
    check(
        (not r["ok"]) and r["verdict"] == "UNSCORED",
        "short window UNSCORED (soft ≠ PASS)",
    )
    r = glass_rate_from_pair(0, 10, 0.0)
    check(r["verdict"] == "BAD_DT", "dt=0 BAD_DT")

    check(abs(IDEAL_GLASS_HZ - 24.2424242424) < 1e-9, "ideal ~24.2424 Hz pin")
    check(abs(IDEAL_GLASS_HZ - 31.25) > 1.0, "NEG: ideal != 31.25 grabber")

    db, plxd, plxd4 = resolve_product_plxd()
    check(db == 0x302FF000, f"product doorbell 0x{db:08X}")
    check(plxd == 0x302FF128, f"product PLXD 0x{plxd:08X}")
    check(plxd4 == 0x302FF12C, f"product PLXD4 0x{plxd4:08X}")

    if fails:
        print(f"self-test: {fails} failure(s)", file=sys.stderr)
        return RC_FAIL
    print("self-test: OK pure modular12 glass rate (no device)")
    print(f"ideal_glass_hz_clk_pix30={IDEAL_GLASS_HZ:.10f} tag=derived not_RATE_PASS")
    print("live_75065b0c_pred=STALE_OR_ZERO until bank_vsync pack + cutb-sched-reg RBF")
    print(f"post_cutb_sched_reg_pred_hz~={IDEAL_GLASS_HZ:.4f} (clk_pix 30 MHz pack)")
    return RC_OK


def load_samples(path: Path) -> list[tuple[float, int]]:
    """Lines: mono_s glass_u12  OR  mono_s 0xPLXD_HI  OR  mono_s plxd_hi_hex."""
    samples: list[tuple[float, int]] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.replace(",", " ").split()
        if len(parts) < 2:
            continue
        t = float(parts[0])
        tok = parts[1]
        if tok.lower().startswith("0x") or (len(tok) > 4 and all(c in "0123456789abcdefABCDEF" for c in tok)):
            hi = int(tok, 16)
            # Heuristic: if value has bits above glass field, treat as PLXD hi word.
            if hi > MASK:
                g = glass_from_plxd_hi(hi)
            else:
                g = hi & MASK
        else:
            g = int(tok, 0) & MASK
        samples.append((t, g))
    return samples


def rate_from_samples(samples: list[tuple[float, int]], min_dt_s: float) -> dict:
    if len(samples) < 2:
        return {
            "ok": False,
            "verdict": "UNSCORED",
            "note": "need ≥2 samples",
            "rate_hz": None,
        }
    t0, c0 = samples[0]
    t1, c1 = samples[-1]
    return glass_rate_from_pair(c0, c1, t1 - t0, min_dt_s=min_dt_s)


def print_addrs() -> int:
    db, plxd, plxd4 = resolve_product_plxd()
    print("=== measure_glass_vsync_rate addresses (layout SoT) ===")
    print(f"product_doorbell=0x{db:08X} src=ddr_frame_layout.hpp")
    print(f"product_plxd_lo=0x{plxd:08X}  # magic+low status; doorbell+0x128")
    print(f"product_plxd_hi=0x{plxd4:08X}  # hi word: frames_done[31:16] glass[15:4]")
    print("field=glass_vsync[11:0] = (plxd_hi >> 4) & 0xFFF  # NOT frames_done")
    print(f"ideal_glass_hz_clk_pix30={IDEAL_GLASS_HZ:.10f} tag=derived")
    print("live_75065b0c_pred=STALE_OR_ZERO (no glass pack on that RBF)")
    print("post_cutb_sched_reg_pred≈24.242 Hz (30 MHz clk_pix; not 31.25 grabber)")
    print("PARENT recipe (device; agents must not SSH):")
    print(f"  t0=$(date +%s.%N); g0=$(( ($(busybox devmem 0x{plxd4:08X} 32) >> 4) & 0xFFF ))")
    print("  sleep 2.1")
    print(f"  t1=$(date +%s.%N); g1=$(( ($(busybox devmem 0x{plxd4:08X} 32) >> 4) & 0xFFF ))")
    print("  # then: tools/measure_glass_vsync_rate.py --from-samples with two lines")
    return RC_OK


def live_parent(duration_s: float, host: str, password: str) -> int:
    """Parent-only: SSH poll PLXD hi. Agents must not call this."""
    # Intentionally minimal: requires sshpass/ssh. Refuse if tools missing.
    import shutil
    import subprocess

    if not shutil.which("ssh") or not shutil.which("sshpass"):
        print("live: ssh/sshpass missing — cannot poll device", file=sys.stderr)
        return RC_UNSCORED
    _, _, plxd4 = resolve_product_plxd()
    # busybox devmem on MiSTer
    cmd = (
        f"busybox devmem 0x{plxd4:08X} 32"
    )
    def read_hi() -> int:
        r = subprocess.run(
            [
                "sshpass",
                "-p",
                password,
                "ssh",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "ConnectTimeout=5",
                f"root@{host}",
                cmd,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if r.returncode != 0:
            raise RuntimeError(f"ssh/devmem rc={r.returncode} err={r.stderr.strip()}")
        return int(r.stdout.strip(), 16)

    t0 = time.time()
    hi0 = read_hi()
    g0 = glass_from_plxd_hi(hi0)
    time.sleep(max(duration_s, MIN_DT_S))
    t1 = time.time()
    hi1 = read_hi()
    g1 = glass_from_plxd_hi(hi1)
    res = glass_rate_from_pair(g0, g1, t1 - t0, min_dt_s=MIN_DT_S)
    print(
        f"live_sample hi0=0x{hi0:08X} glass0={g0} hi1=0x{hi1:08X} glass1={g1} "
        f"dt_s={res['dt_s']:.6f}"
    )
    print(
        f"verdict={res['verdict']} ok={int(res['ok'])} delta={res['delta']} "
        f"rate_hz={res['rate_hz']} note={res['note']}"
    )
    print(f"ideal_glass_hz_clk_pix30={IDEAL_GLASS_HZ:.10f} tag=derived not_auto_pass")
    if res["verdict"] == "MEASURED":
        return RC_OK
    if res["verdict"] in ("STALE_OR_ZERO", "UNSCORED", "BAD_DT"):
        return RC_UNSCORED
    return RC_FAIL


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--self-test", action="store_true", help="pure modular math; no device")
    p.add_argument("--print-addrs", action="store_true", help="product PLXD addrs + parent recipe")
    p.add_argument(
        "--from-samples",
        type=Path,
        help="file of mono_s glass_u12 (or plxd_hi hex) lines",
    )
    p.add_argument("--min-dt-s", type=float, default=MIN_DT_S, help="min wall window (default 2.0)")
    p.add_argument(
        "--live",
        action="store_true",
        help="PARENT-ONLY device poll (requires --i-am-parent)",
    )
    p.add_argument(
        "--i-am-parent",
        action="store_true",
        help="acknowledge parent-only device access",
    )
    p.add_argument("--duration-s", type=float, default=2.1, help="live poll window")
    p.add_argument("--host", default="", help="MiSTer host for --live (parent)")
    p.add_argument("--password", default="", help="SSH password for --live (parent)")
    args = p.parse_args(argv)

    if args.self_test:
        return self_test()
    if args.print_addrs:
        return print_addrs()
    if args.from_samples:
        samples = load_samples(args.from_samples)
        res = rate_from_samples(samples, min_dt_s=args.min_dt_s)
        print(f"n_samples={len(samples)}")
        if samples:
            print(f"c0={samples[0][1]} c1={samples[-1][1]} t0={samples[0][0]} t1={samples[-1][0]}")
        print(
            f"verdict={res.get('verdict')} ok={int(bool(res.get('ok')))} "
            f"delta={res.get('delta')} dt_s={res.get('dt_s')} rate_hz={res.get('rate_hz')} "
            f"note={res.get('note')}"
        )
        print(f"ideal_glass_hz_clk_pix30={IDEAL_GLASS_HZ:.10f} tag=derived not_auto_pass")
        if res.get("verdict") == "MEASURED":
            return RC_OK
        return RC_UNSCORED
    if args.live:
        if not args.i_am_parent:
            print(
                "REFUSE --live without --i-am-parent (device is parent-only; agents must not SSH)",
                file=sys.stderr,
            )
            return RC_USAGE
        host = args.host or "192.168.1.183"
        password = args.password or "1"
        return live_parent(args.duration_s, host, password)

    p.print_help()
    return RC_USAGE


if __name__ == "__main__":
    sys.exit(main())
