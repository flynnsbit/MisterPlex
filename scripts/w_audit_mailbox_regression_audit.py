#!/usr/bin/env python3
"""W-AUDIT checker for the fb4bad84 PLXS/PLXD regression claim.

Read-only by default.  With --live-read it performs devmem reads only; it never
pokes sentinels, reloads cores, or touches capture devices.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


DEFAULT_INTEG = Path("/home/flynnsbit/Projects/mp-wt-integ")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def cpp_hex(text: str, name: str) -> int:
    m = re.search(rf"\b{name}\s*=\s*(0x[0-9A-Fa-f]+)u?", text)
    if not m:
        raise SystemExit(f"missing C++ constant {name}")
    return int(m.group(1), 16)


def sv_hex(text: str, name: str) -> int:
    m = re.search(rf"\b{name}\s*=\s*32'h([0-9A-Fa-f_]+)", text)
    if not m:
        raise SystemExit(f"missing SV constant {name}")
    return int(m.group(1).replace("_", ""), 16)


def git(root: Path, *args: str) -> str:
    p = subprocess.run(
        ["git", "-C", str(root), "--no-pager", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return p.stdout.strip() if p.returncode == 0 else f"UNKNOWN(rc={p.returncode})"


def summarize_samples(log: Path) -> dict[str, int | str]:
    rows = []
    if not log.exists():
        return {"path": str(log), "n": 0}
    for line in read(log).splitlines():
        if line.startswith("sample="):
            fields = dict(tok.split("=", 1) for tok in line.split() if "=" in tok)
            rows.append(fields)
    if not rows:
        return {"path": str(log), "n": 0}
    vals = [int(r["raw"], 16) for r in rows]
    frames = [(v >> 16) & 0xFFFF for v in vals]
    disp = [(v >> 2) & 1 for v in vals]
    swap = [(v >> 3) & 1 for v in vals]
    free = [v & 3 for v in vals]
    return {
        "path": str(log),
        "n": len(vals),
        "first_raw": rows[0]["raw"],
        "last_raw": rows[-1]["raw"],
        "frames_first": frames[0],
        "frames_last": frames[-1],
        "frames_delta": frames[-1] - frames[0],
        "raw_distinct": len(set(vals)),
        "disp_transitions": sum(a != b for a, b in zip(disp, disp[1:])),
        "swap_zero": sum(x == 0 for x in swap),
        "free_nonzero": sum(x != 0 for x in free),
    }


def print_summary(label: str, summary: dict[str, int | str]) -> None:
    print(f"{label}: path={summary['path']}")
    if summary["n"] == 0:
        print("  samples=0")
        return
    print(
        "  samples={n} first_raw={first_raw} last_raw={last_raw} "
        "frames={frames_first}->{frames_last} delta={frames_delta} "
        "distinct_raw={raw_distinct} disp_transitions={disp_transitions} "
        "swap_zero={swap_zero}/{n} free_nonzero={free_nonzero}/{n}".format(**summary)
    )


def live_read(host: str, user: str, password: str) -> None:
    addrs = [
        "0x3007F100",
        "0x3007F104",
        "0x3007F128",
        "0x3007F12C",
        "0x300FF100",
        "0x300FF104",
        "0x300FF128",
        "0x300FF12C",
    ]
    remote = (
        'echo md5=$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -d" " -f1); '
        'echo core=$(cat /tmp/CORENAME 2>/dev/null); '
        f'for a in {" ".join(addrs)}; do printf "%s=" "$a"; devmem "$a" 32; done; '
        "sleep 1; echo after_1s; "
        f'for a in {" ".join(addrs)}; do printf "%s=" "$a"; devmem "$a" 32; done'
    )
    p = subprocess.run(
        [
            "sshpass",
            "-p",
            password,
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "ConnectTimeout=12",
            f"{user}@{host}",
            remote,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    print("---LIVE_READ_RAW---")
    print(p.stdout.rstrip())
    print(f"live_read_rc={p.returncode}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--integ-root", type=Path, default=DEFAULT_INTEG)
    ap.add_argument("--live-read", action="store_true")
    ap.add_argument("--host", default="192.168.1.183")
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="1")
    args = ap.parse_args()

    root = args.integ_root
    spec = read(root / "host/libmisterplex/mailbox_abi_spec.hpp")
    layout = read(root / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh")
    present = read(root / "fpga/Plex_MiSTer/rtl/present_core.sv")

    host_plxs = cpp_hex(spec, "kPlxsAddr")
    host_plxd = cpp_hex(spec, "kPlxdAddr")
    yuv_doorbell = sv_hex(layout, "DDR_FRAME_YUV420P_DOORBELL_PHYS")
    rtl_plxs = yuv_doorbell + 0x100
    rtl_plxd = yuv_doorbell + 0x128
    uses_yuv = ".DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)" in present

    print(f"branch={git(root, 'rev-parse', '--abbrev-ref', 'HEAD')}")
    print(f"commit={git(root, 'rev-parse', '--short', 'HEAD')}")
    print(f"present_core_uses_yuv_doorbell={uses_yuv}")
    print(f"host_PLXS=0x{host_plxs:08X} host_PLXD=0x{host_plxd:08X}")
    print(f"rtl_yuv_doorbell=0x{yuv_doorbell:08X}")
    print(f"rtl_yuv_PLXS=0x{rtl_plxs:08X} rtl_yuv_PLXD=0x{rtl_plxd:08X}")
    print(f"address_delta_PLXS=0x{rtl_plxs - host_plxs:08X}")
    print(f"address_delta_PLXD=0x{rtl_plxd - host_plxd:08X}")

    logs = root / ".copilot-logs"
    print_summary("predeploy_legacy_page", summarize_samples(logs / "wfit2-telemetry-PREDEPLOY-00eebd5e.log"))
    print_summary("postdeploy_legacy_page", summarize_samples(logs / "wfit2-telemetry-POSTDEPLOY-fb4bad84-idle.log"))

    print("---INTERPRETATION---")
    if uses_yuv and (host_plxs != rtl_plxs or host_plxd != rtl_plxd):
        print(
            "BROKEN_CLAIM: W-FIT probed the legacy fixed 0x3007F1xx page, "
            "but the fitted DDR_FRAME_STORE RTL is parameterized to publish "
            "PLXS/PLXD at the YUV doorbell page 0x300FF1xx."
        )
        print(
            "Measured silence at 0x3007F100/0x3007F128 is therefore not evidence "
            "that the fabric stopped publishing PLXS/PLXD."
        )
    else:
        print("No PLXS/PLXD address mismatch found by this static audit.")

    if args.live_read:
        live_read(args.host, args.user, args.password)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
