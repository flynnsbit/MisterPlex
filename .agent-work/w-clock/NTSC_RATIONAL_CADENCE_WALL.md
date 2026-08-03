# NTSC rational cadence wall (rd-duck)

## Verdict
**Integer q5 `content_fps` cannot source-lock common NTSC rates.**
B15 tests for integer 24/25/30 remain valid. Claims of source-lock / judder
control for **23.976 / 29.97 are forbidden** until a rational (or milli-Hz)
ABI and a real pending-bank model exist.

## Verified arithmetic (20 MHz, H=1182)
| Class | Beam Hz | NTSC | Δ Hz | Slip period |
|-------|---------|------|------|-------------|
| Film V=705 | 24.000672 | 23.976024 (24000/1001) | 0.024648 | **~40.57 s** |
| TV V=564 | 30.000840 | 29.970030 (30000/1001) | 0.030810 | **~32.46 s** |

ppm ≈ **1028** both. Exact clocks/frame for 24000/1001 at 20 MHz =
**833541.666…** (non-integer) → **no** integer H×V hits true NTSC film rate.

## Why tests stay green
- TB synthesizes integer fps availability.
- DDR swap = `fstart && swap_pending` (C1) — ignores `advance_unique`.
- Continuous `swap_pending=1` + integer 1:1 advance models a full buffer being
  drained 1028 ppm fast — not modeled in B15 framecount.

## q5 bucket (w-path)
`contentFpsIntegerForPlxg`: 23.5–24.5 → 24, 29.5–30.5 → 30
(`plxg_q5_aspect_cadence.hpp`). Fabric never sees 1001.

## Recommendation
1. **Short-term (C):** V_TOTAL class from integer fps only; unique banks solely
   via ARM rational publish → `swap_pending`. Never claim fabric NTSC lock.
2. **ABI (B, parent):** transport `fps_num/fps_den` (or milli-Hz) for cadence;
   w-clock consumes; w-mem latch; w-path publish from existing rational.
3. **Not sufficient (D):** fractional V_TOTAL alone cannot exact-match at 20 MHz.

## Gate
`tests/unit/test_ntsc_rational_cadence_wall.sh`
