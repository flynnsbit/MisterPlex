#!/usr/bin/env python3
"""Decide, arithmetically, whether a decoded picture buffer can live on-chip.

The fleet has twice capacity-planned against a number nobody decomposed. This
does the decomposition: it derives the picture-store requirement from geometry
and compares it against device totals read out of a real fit report.

Two disciplines are enforced rather than remembered:

* Device totals must be **bound to an RBF md5**. 40 fit reports exist on this
  host and most describe builds nobody is running; reading the wrong one is a
  silent way to be confidently wrong. Without --expect-rbf-md5 the verdict is
  UNBOUND and the exit code is 2, never a pass.
* The reported number is what the *fitter* will allocate, not what the array
  literally needs: Quartus rounds a byte array up to a power-of-two depth.
  Both figures are printed; the rounded one is the one that must fit.

Exit codes: 0 fits on-chip, 1 does not fit, 2 usage/binding error.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

TOTAL_BITS_RE = re.compile(
    r"Total block memory bits\s*;\s*([\d,]+)\s*/\s*([\d,]+)")


def parse_fit_report(path: Path) -> tuple[int, int]:
    """Return (used_block_bits, device_block_bits) from a Quartus fit report."""
    text = path.read_text(errors="replace")
    match = TOTAL_BITS_RE.search(text)
    if not match:
        raise SystemExit(
            f"DPB_CAPACITY_ERROR: no 'Total block memory bits' row in {path}; "
            "refusing to guess device totals")
    used = int(match.group(1).replace(",", ""))
    total = int(match.group(2).replace(",", ""))
    return used, total


def rbf_md5(fit_report: Path) -> str | None:
    for name in ("Plex.rbf", "Plex.sof"):
        candidate = fit_report.parent / name
        if candidate.exists():
            return hashlib.md5(candidate.read_bytes()).hexdigest()
    return None


def picture_bytes(width: int, height: int) -> int:
    """4:2:0 planar picture, chroma planes rounded up like the RTL does."""
    chroma_w = (width + 1) // 2
    chroma_h = (height + 1) // 2
    return width * height + 2 * (chroma_w * chroma_h)


def pow2_depth(depth: int) -> int:
    size = 1
    while size < depth:
        size <<= 1
    return size


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--fit-report", required=True, type=Path)
    ap.add_argument("--expect-rbf-md5", default=None,
                    help="md5 of the bitstream this report must describe")
    ap.add_argument("--width", required=True, type=int)
    ap.add_argument("--height", required=True, type=int)
    ap.add_argument("--ref-frames", type=int, default=1,
                    help="max_num_ref_frames; the store also holds the picture "
                         "currently being reconstructed")
    ap.add_argument("--assume-freed-bits", type=int, default=0,
                    help="block bits assumed released by retiring other logic")
    ap.add_argument("--label", default="dpb")
    args = ap.parse_args(argv)

    if args.width <= 0 or args.height <= 0 or args.ref_frames < 0:
        print("DPB_CAPACITY_ERROR: geometry and ref-frames must be positive",
              file=sys.stderr)
        return 2
    if not args.fit_report.exists():
        print(f"DPB_CAPACITY_ERROR: no such fit report: {args.fit_report}",
              file=sys.stderr)
        return 2

    used_bits, device_bits = parse_fit_report(args.fit_report)
    actual_md5 = rbf_md5(args.fit_report)

    if not args.expect_rbf_md5:
        print(f"DPB_CAPACITY_UNBOUND: {args.fit_report} was not bound to a "
              f"bitstream (--expect-rbf-md5 absent). Device totals from an "
              f"unidentified build are not evidence. observed_rbf_md5="
              f"{actual_md5 or 'none'}", file=sys.stderr)
        return 2
    if actual_md5 is None:
        print(f"DPB_CAPACITY_UNBOUND: no Plex.rbf/Plex.sof beside "
              f"{args.fit_report}; cannot confirm which build this describes",
              file=sys.stderr)
        return 2
    if not actual_md5.startswith(args.expect_rbf_md5):
        print(f"DPB_CAPACITY_UNBOUND: report describes rbf md5={actual_md5}, "
              f"expected {args.expect_rbf_md5}", file=sys.stderr)
        return 2

    pictures = args.ref_frames + 1
    per_picture = picture_bytes(args.width, args.height)
    store_bytes = per_picture * pictures
    exact_bits = store_bytes * 8
    fitted_bits = pow2_depth(store_bytes) * 8

    free_bits = device_bits - used_bits + args.assume_freed_bits

    print(f"Scope: {args.label} {args.width}x{args.height} 4:2:0, "
          f"ref_frames={args.ref_frames} -> {pictures} pictures held")
    print(f"BOUND report={args.fit_report} rbf_md5={actual_md5}")
    print(f"Raw: picture_bytes={per_picture} store_bytes={store_bytes} "
          f"exact_bits={exact_bits} fitted_bits_pow2_depth={fitted_bits}")
    print(f"Raw: device_block_bits={device_bits} used_block_bits={used_bits} "
          f"assumed_freed_bits={args.assume_freed_bits} "
          f"available_bits={free_bits}")
    print(f"Raw: one_picture_exact_bits={per_picture * 8} "
          f"= {100.0 * per_picture * 8 / device_bits:.1f}% of the whole device")

    if fitted_bits <= free_bits:
        print(f"DPB_CAPACITY_FITS {args.label}: fitted_bits={fitted_bits} <= "
              f"available_bits={free_bits}")
        return 0

    print(f"DPB_CAPACITY_EXCEEDS {args.label}: fitted_bits={fitted_bits} > "
          f"available_bits={free_bits}, short by {fitted_bits - free_bits} "
          f"bits. An on-chip picture store is not merely tight, it is "
          f"arithmetically impossible at this geometry; the store must be "
          f"external (DDR).", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
