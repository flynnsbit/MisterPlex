#!/usr/bin/env python3
"""Exact cadence audit for the true-480 fixed native beam.

The candidate beam is 10 MHz / (672 * 496) = 78125/2604 Hz.  Video frames
remain host-paced from the exact rational source clock; the FPGA frame store
only makes a pending frame visible on a beam boundary.  This model therefore
checks sample-and-hold cadence, not the legacy integer present_cadence bucket.

No device and no floating-point timing decisions are used.
"""
from __future__ import annotations

import sys
from collections import Counter
from fractions import Fraction


BEAM_HZ = Fraction(10_000_000, 672 * 496)
BEAM_PERIOD = 1 / BEAM_HZ
DEFAULT_PRESENT_LEAD = Fraction(40, 1000)

# name, source Hz, unique source frames/cycle, beam ticks/cycle,
# repeated beam ticks/cycle, cyclic spacing between repeat ticks
CASES = (
    (
        "24000/1001",
        Fraction(24_000, 1001),
        71_424,
        89_375,
        17_951,
        {4: 380, 5: 17_571},
    ),
    ("24/1", Fraction(24, 1), 62_496, 78_125, 15_629, {4: 20, 5: 15_609}),
    ("25/1", Fraction(25, 1), 2_604, 3_125, 521, {5: 1, 6: 520}),
    (
        "30000/1001",
        Fraction(30_000, 1001),
        17_856,
        17_875,
        19,
        {940: 4, 941: 15},
    ),
    ("30/1", Fraction(30, 1), 15_624, 15_625, 1, {15_625: 1}),
)

NOMINAL_TICKS_PER_SOURCE = {
    "24000/1001": Fraction(5, 4),
    "24/1": Fraction(5, 4),
    "25/1": Fraction(6, 5),
    "30000/1001": Fraction(1, 1),
    "30/1": Fraction(1, 1),
}


def ceil_fraction(value: Fraction) -> int:
    return -(-value.numerator // value.denominator)


def repeat_gap_counts(source_per_tick: Fraction) -> Counter[int]:
    """Return cyclic distances between held/repeated beam ticks."""
    p = source_per_tick.numerator
    q = source_per_tick.denominator
    previous = 0
    repeat_ticks: list[int] = []
    for tick in range(1, q + 1):
        current = (tick * p) // q
        delta = current - previous
        if delta == 0:
            repeat_ticks.append(tick)
        elif delta != 1:
            raise AssertionError(f"beam skipped {delta - 1} source frames at tick {tick}")
        previous = current

    gaps = [
        repeat_ticks[i + 1] - repeat_ticks[i]
        for i in range(len(repeat_ticks) - 1)
    ]
    if repeat_ticks:
        gaps.append(q + repeat_ticks[0] - repeat_ticks[-1])
    return Counter(gaps)


def main() -> int:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    check(BEAM_HZ == Fraction(78_125, 2_604), "beam rate must reduce exactly")
    check(BEAM_HZ > 30, "beam must be slightly faster than 30 Hz")
    check(BEAM_PERIOD == Fraction(20_832, 625_000), "beam period must be 33.3312 ms")

    for name, source_hz, source_frames, beam_ticks, repeats, expected_gaps in CASES:
        source_per_tick = source_hz / BEAM_HZ
        check(
            source_per_tick == Fraction(source_frames, beam_ticks),
            f"{name}: wrong reduced source/beam ratio",
        )
        check(source_hz < BEAM_HZ, f"{name}: source must not outrun the beam")
        check(beam_ticks - source_frames == repeats, f"{name}: wrong repeat count")
        check(
            repeat_gap_counts(source_per_tick) == Counter(expected_gaps),
            f"{name}: wrong exact repeat spacing",
        )

        # A fixed host lead changes only cadence phase.  Consecutive exact-rational
        # source releases still land one or two beam ticks apart: never zero
        # (source drop/overwrite), and every two-tick gap is one held beam frame.
        base_frame = 100
        first_ticks: list[int] = []
        latch_delays: list[Fraction] = []
        for frame in range(base_frame, base_frame + source_frames + 1):
            release_time = Fraction(frame, 1) / source_hz - DEFAULT_PRESENT_LEAD
            tick = ceil_fraction(release_time * BEAM_HZ)
            first_ticks.append(tick)
            latch_delays.append(Fraction(tick, 1) / BEAM_HZ - release_time)

        tick_steps = [
            first_ticks[i + 1] - first_ticks[i] for i in range(source_frames)
        ]
        check(set(tick_steps) <= {1, 2}, f"{name}: beam-induced source drop")
        check(tick_steps.count(2) == repeats, f"{name}: lead changed repeat count")
        check(
            first_ticks[-1] - first_ticks[0] == beam_ticks,
            f"{name}: cadence cycle does not close",
        )
        check(
            all(Fraction(0) <= delay < BEAM_PERIOD for delay in latch_delays),
            f"{name}: VSync quantization escaped one beam period",
        )
        first_present_errors = [
            delay - DEFAULT_PRESENT_LEAD for delay in latch_delays
        ]
        check(
            all(
                Fraction(0) - DEFAULT_PRESENT_LEAD <= error
                < BEAM_PERIOD - DEFAULT_PRESENT_LEAD
                for error in first_present_errors
            ),
            f"{name}: fixed lead became an accumulating A/V error",
        )
        check(
            latch_delays[0] == latch_delays[-1],
            f"{name}: phase accumulated across an exact cadence cycle",
        )
        rises = any(b > a for a, b in zip(latch_delays, latch_delays[1:]))
        falls = any(b < a for a, b in zip(latch_delays, latch_delays[1:]))
        check(rises and falls, f"{name}: phase error must be a bounded sawtooth")

        # Show why an uncorrected nominal cadence is not enough.  A permanent
        # 5:4, 6:5, or 1:1 pattern advances content at beam/multiplier instead
        # of at the source rational and therefore accumulates real A/V error.
        nominal_rate = BEAM_HZ / NOMINAL_TICKS_PER_SOURCE[name]
        naive_lead_per_hour = (nominal_rate / source_hz - 1) * 3600
        expected_naive_lead = (
            Fraction(475, 124) if source_hz.denominator == 1001 else Fraction(50, 217)
        )
        check(
            naive_lead_per_hour == expected_naive_lead,
            f"{name}: wrong nominal-cadence long-run error",
        )

        cycle_seconds = Fraction(beam_ticks, 1) / BEAM_HZ
        print(
            f"{name}: {source_frames} source / {beam_ticks} beam, "
            f"repeats={repeats}, beam_drops=0, cycle={float(cycle_seconds):.4f}s, "
            f"naive_drift={float(naive_lead_per_hour):.6f}s/hour"
        )

    # Neither 24-family rate can have equal-duration source frames on this beam:
    # both exact ratios require a mix of one- and two-tick holds (5:4-class judder).
    for name, source_hz, *_ in CASES[:2]:
        ticks_per_source = BEAM_HZ / source_hz
        check(
            ticks_per_source.denominator != 1,
            f"{name}: fixed beam unexpectedly became source-matched",
        )

    if failures:
        print("FAIL test_fixed30_cadence:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("PASS test_fixed30_cadence")
    return 0


if __name__ == "__main__":
    sys.exit(main())
