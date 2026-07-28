#!/usr/bin/env python3
"""Derive DDR frame-layout addresses from the single source of truth.

host/libmisterplex/ddr_frame_layout.hpp is the ARM/RTL layout contract. Tools
that must ship addresses somewhere the header cannot be included -- notably
scripts/ddr_frame_dump_device.py, which is piped to the MiSTer over bare stdin
-- read them from here instead of restating them. Restating them is what the
runtime DDR layout literal sweep in tests/unit/test_rtl_invariants.py rejects,
and it is how an ARM writer and a readback tool silently disagree.

Mailbox addresses come from host/libmisterplex/mailbox_abi_spec.hpp for the
same reason.

Usage:
    python3 scripts/ddr_layout_consts.py --print          # human readable
    python3 scripts/ddr_layout_consts.py --dump-args      # argv for the device script
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAYOUT_HPP = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"
MAILBOX_HPP = ROOT / "host/libmisterplex/mailbox_abi_spec.hpp"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def cpp_const(text: str, name: str) -> int:
    """Read `constexpr <type> <name> = <int literal>;` out of a header."""
    m = re.search(
        r"\bconstexpr\s+[A-Za-z_][A-Za-z0-9_:<>\s\*]*?\b"
        + re.escape(name)
        + r"\s*=\s*(0[xX][0-9a-fA-F_]+|\d[\d_]*)\s*[uUlL]*\s*;",
        text,
    )
    if not m:
        raise KeyError(f"constant {name} not found")
    return int(m.group(1).replace("_", ""), 0)


def layout() -> dict[str, int]:
    if not LAYOUT_HPP.is_file():
        raise FileNotFoundError(LAYOUT_HPP)
    text = _strip_comments(LAYOUT_HPP.read_text())
    out = {
        "ddr_base": cpp_const(text, "kDdrFramePhysBase"),
        "bank_stride": cpp_const(text, "kPlex480pYuv420pBankStride"),
        "frame_bytes": cpp_const(text, "kPlex480pYuv420pBytes"),
        "doorbell_phys": cpp_const(text, "kPlex480pYuv420pDoorbellPhys"),
        "coded_width": cpp_const(text, "kPlex480pCodedWidth"),
        "coded_height": cpp_const(text, "kPlex480pCodedHeight"),
    }
    # Cross-check the header against itself: an I420 frame is w*h*3/2. If this
    # ever trips, the header is internally inconsistent and every consumer of
    # it -- ARM writer included -- is suspect.
    derived = out["coded_width"] * out["coded_height"] * 3 // 2
    if derived != out["frame_bytes"]:
        raise ValueError(
            f"ddr_frame_layout.hpp inconsistent: {out['coded_width']}x"
            f"{out['coded_height']} I420 = {derived} bytes but "
            f"kPlex480pYuv420pBytes = {out['frame_bytes']}"
        )
    if out["bank_stride"] < out["frame_bytes"]:
        raise ValueError(
            f"bank stride {out['bank_stride']} is smaller than one frame "
            f"({out['frame_bytes']} bytes); banks would overlap"
        )
    return out


def mailboxes() -> dict[str, int]:
    if not MAILBOX_HPP.is_file():
        raise FileNotFoundError(MAILBOX_HPP)
    text = _strip_comments(MAILBOX_HPP.read_text())
    return {
        "plxd_phys": cpp_const(text, "kPlxdAddr"),
        "plxf_phys": cpp_const(text, "kPlxfAddr"),
    }


def device_args() -> list[str]:
    lay = layout()
    mbx = mailboxes()
    return [
        "--ddr-base", hex(lay["ddr_base"]),
        "--bank-stride", hex(lay["bank_stride"]),
        "--frame-bytes", str(lay["frame_bytes"]),
        "--doorbell-phys", hex(lay["doorbell_phys"]),
        "--plxd-phys", hex(mbx["plxd_phys"]),
        "--plxf-phys", hex(mbx["plxf_phys"]),
    ]


def _self_test() -> int:
    """Prove the derivation reads real values and rejects an inconsistent header.

    What this literally compares: that every constant is parsed out of the two
    canonical headers, that I420 frame bytes equal w*h*3/2, and that a bank
    stride smaller than a frame is refused.
    What it does NOT cover: whether the headers agree with the RTL mirror
    (test_rtl_invariants.py owns that), and whether the addresses are the ones
    the resident bitstream actually uses (only a live readback can show that).
    """
    print("Scope: 6 layout constants + 2 mailbox constants = 8 parsed values, "
          "3 must-fail mutations")
    failures = 0

    lay = layout()
    mbx = mailboxes()
    for key, val in list(lay.items()) + list(mbx.items()):
        if not isinstance(val, int) or val <= 0:
            print(f"FAIL {key} parsed as {val!r}")
            failures += 1
    print(f"parsed_values={len(lay) + len(mbx)}/8")

    cases = [
        (
            "frame bytes inconsistent with coded geometry",
            "constexpr int kPlex480pYuv420pBytes = 449280;",
            "constexpr int kPlex480pYuv420pBytes = 449281;",
        ),
        (
            "bank stride smaller than one frame",
            "constexpr uint32_t kPlex480pYuv420pBankStride = 0x00080000u;",
            "constexpr uint32_t kPlex480pYuv420pBankStride = 0x00001000u;",
        ),
        (
            "missing constant",
            "constexpr uint32_t kDdrFramePhysBase",
            "constexpr uint32_t kDdrFramePhysBaseRENAMED",
        ),
    ]
    original = LAYOUT_HPP.read_text()
    for name, needle, replacement in cases:
        if needle not in original:
            print(f"FAIL red-case {name!r}: anchor text not found; "
                  "the self-test has drifted from the header")
            failures += 1
            continue
        try:
            LAYOUT_HPP.write_text(original.replace(needle, replacement, 1))
            try:
                layout()
            except (ValueError, KeyError) as exc:
                print(f"RED OK {name}: {type(exc).__name__}")
            else:
                print(f"FAIL red-case {name!r} was accepted")
                failures += 1
        finally:
            LAYOUT_HPP.write_text(original)

    if LAYOUT_HPP.read_text() != original:
        print("FAIL header was not restored after mutation")
        failures += 1
    layout()

    if failures:
        print(f"RESULT FAIL ddr_layout_consts self-test failures={failures}")
        return 1
    print("RESULT PASS ddr_layout_consts derives 8 values and rejects 3 bad headers")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump-args", action="store_true")
    ap.add_argument("--print", dest="show", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return _self_test()
    if args.dump_args:
        print(" ".join(device_args()))
        return 0
    values = dict(layout())
    values.update(mailboxes())
    for key, val in values.items():
        print(f"{key}={val} ({hex(val)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
