#!/usr/bin/env python3
"""Compute whether a live-content product DPB can fit on Cyclone V M10K."""

from __future__ import annotations

import math

DEVICE_M10K = 553
CURRENT_FIT_M10K = 453
STUB_DPB_M10K = 256
STUB_DPB_BITS = 2_097_152
LIVE_W = 624
LIVE_H = 480


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def pow2_ceil(n: int) -> int:
    return 1 << (n - 1).bit_length()


def main() -> int:
    baseline_no_stub = CURRENT_FIT_M10K - STUB_DPB_M10K
    bits_per_fitted_m10k = STUB_DPB_BITS // STUB_DPB_M10K
    physical_bits_per_m10k = 10_240

    luma = LIVE_W * LIVE_H
    chroma_each = (LIVE_W // 2) * (LIVE_H // 2)
    frame_bytes = luma + 2 * chroma_each
    two_bank_bytes = 2 * frame_bytes

    print(f"DEVICE_M10K {DEVICE_M10K}")
    print(f"CURRENT_FIT_M10K {CURRENT_FIT_M10K}")
    print(f"STUB_DPB_M10K {STUB_DPB_M10K}")
    print(f"BASELINE_WITHOUT_STUB_DPB_M10K {baseline_no_stub}")
    print(f"FITTED_8BIT_DPB_BITS_PER_M10K {bits_per_fitted_m10k}")
    print(f"LIVE_FRAME {LIVE_W}x{LIVE_H} luma={luma} chroma_each={chroma_each} i420_bytes={frame_bytes}")

    for banks, why in [(1, "one frame only, not sufficient for P read-prev/write-current"), (2, "reference plus current reconstruction")]:
        bytes_needed = banks * frame_bytes
        bits_needed = bytes_needed * 8
        rounded_bytes = pow2_ceil(bytes_needed)
        rounded_bits = rounded_bytes * 8
        exact_8k = ceil_div(bits_needed, bits_per_fitted_m10k)
        rounded_8k = ceil_div(rounded_bits, bits_per_fitted_m10k)
        ideal_10k = ceil_div(bits_needed, physical_bits_per_m10k)
        print(f"SCENARIO banks={banks} note={why}")
        print(f"  bytes={bytes_needed} bits={bits_needed} rounded_addr_bytes={rounded_bytes} rounded_bits={rounded_bits}")
        print(f"  m10k_exact_at_observed_8bit_packing={exact_8k} total_with_current_baseline={baseline_no_stub + exact_8k} fits={int(baseline_no_stub + exact_8k <= DEVICE_M10K)}")
        print(f"  m10k_rounded_power2_at_observed_8bit_packing={rounded_8k} total_with_current_baseline={baseline_no_stub + rounded_8k} fits={int(baseline_no_stub + rounded_8k <= DEVICE_M10K)}")
        print(f"  m10k_theoretical_10240bit_exact={ideal_10k} total_with_current_baseline={baseline_no_stub + ideal_10k} fits={int(baseline_no_stub + ideal_10k <= DEVICE_M10K)}")

    print("CONCLUSION on_chip_product_dpb_for_live_P_content_fits=NO")
    print("REASON live P frames require reading the previous reference while writing the current frame; two banks exceed the device even under ideal packing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
