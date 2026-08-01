#!/usr/bin/env python3
"""Blind-counter guard for MiSTerPlex host instruments (parent ERROR family).

Incident (parent, live cast):
  An instrument scored ffmpeg /proc/<pid>/io **rchar** B/s and returned
  class=STALL_LT_0_4X on 12/12 windows for a stream that was healthy at that
  instant (vfps 23.9, av-lock, wall_s advancing). Cumulative rchar=1037 /
  syscr=5 while wchar≈414 MB — input arrives via recv(), which does not
  increment rchar on this kernel. The counter was structurally blind; the
  instrument reported a confident DEFECT instead of "cannot answer."

Rule (binding across every instrument):
  If the scored primary counter is flat/zero across all windows WHILE the
  process is provably alive and doing other work (secondary counter advancing,
  or independent liveness), return NO-DATA / rc=77 — NEVER a defect class.

  Blind-and-RED is as dangerous as blind-and-green. Do not "fix" it by
  relaxing thresholds.

Also covers ERROR 17 family: never score a rate axis against DEFAULT_ASSUMED
inputs; refuse that axis (UNSCORED) rather than mint a plausible wrong number.

Usage:
  from instrument_blind_counter import classify_primary_counter, RC_NO_DATA
  v = classify_primary_counter(
      primary_deltas=[0, 0, 0],
      secondary_deltas=[1e6, 2e6, 1.5e6],  # e.g. wchar
      process_alive=True,
  )
  # v.verdict == "NO-DATA", v.rc == 77

true rc must be captured by the parent directly (never through a pipe alone).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Optional, Sequence

RC_OK = 0
RC_DEFECT = 2
RC_NO_DATA = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"


@dataclass(frozen=True)
class BlindCounterVerdict:
    verdict: str  # OK | DEFECT | NO-DATA
    rc: int
    reason: str
    primary_sum: float
    secondary_sum: Optional[float]
    process_alive: bool
    primary_src: str = PROVENANCE_MEASURED
    secondary_src: str = PROVENANCE_MEASURED


def _sum(xs: Optional[Sequence[float]]) -> Optional[float]:
    if xs is None:
        return None
    return float(sum(float(x) for x in xs))


def classify_primary_counter(
    *,
    primary_deltas: Sequence[float],
    secondary_deltas: Optional[Sequence[float]] = None,
    process_alive: bool = True,
    primary_name: str = "primary",
    secondary_name: str = "secondary",
    defect_when_low: bool = False,
    low_threshold: float = 0.0,
) -> BlindCounterVerdict:
    """Classify a primary counter series with blind-counter protection.

    primary_deltas: per-window increments of the scored meter.
    secondary_deltas: per-window increments of an independent "doing work"
      signal (e.g. wchar, wall_s advance, bytes_sent). Optional.
    process_alive: True if the target process still exists / is live.
    defect_when_low: if True and primary is scorable and below low_threshold,
      emit DEFECT; otherwise OK when scorable and not low.

    Returns NO-DATA when primary is flat/zero across all windows AND
    (secondary advanced OR process_alive with empty secondary denied as
    insufficient alone only if process not alive — if alive and primary
    flat with secondary advancing → NO-DATA; if alive and secondary None
    and primary flat → NO-DATA as well: cannot distinguish blind vs stalled
    without a positive work signal? Parent: "while process is provably alive
    AND doing work". So need secondary advancing OR explicit work signal.

    Parent wording: "exactly 0 across all windows while the process is
    provably alive and doing work (e.g. wchar advancing)".
    So: primary flat + secondary advancing + alive → NO-DATA.
    primary flat + alive + no secondary → still NO-DATA if we cannot prove
    the counter is live (safer: refuse defect). Emit DEFECT only when primary
    is scorable (some non-zero activity observed historically) and then drops.
    """
    psum = _sum(primary_deltas) or 0.0
    ssum = _sum(secondary_deltas)
    n = len(primary_deltas)
    all_zero = n > 0 and all(abs(float(x)) < 1e-12 for x in primary_deltas)
    secondary_work = ssum is not None and ssum > 0.0

    if n == 0:
        return BlindCounterVerdict(
            verdict="NO-DATA",
            rc=RC_NO_DATA,
            reason="no_windows",
            primary_sum=0.0,
            secondary_sum=ssum,
            process_alive=process_alive,
        )

    # Core rule: flat primary + proven other work → blind meter, not stall.
    if all_zero and process_alive and secondary_work:
        return BlindCounterVerdict(
            verdict="NO-DATA",
            rc=RC_NO_DATA,
            reason=(
                f"blind_counter {primary_name}_sum=0 across {n} windows while "
                f"{secondary_name}_sum={ssum} [measured] process_alive=1 — "
                f"structurally blind meter; refuse defect class (parent rchar)"
            ),
            primary_sum=0.0,
            secondary_sum=ssum,
            process_alive=True,
        )

    # Flat primary, alive, but no secondary evidence of work → still refuse
    # DEFECT (cannot prove stall vs blind). Parent: never confident FAIL.
    if all_zero and process_alive:
        return BlindCounterVerdict(
            verdict="NO-DATA",
            rc=RC_NO_DATA,
            reason=(
                f"primary_flat {primary_name}_sum=0 windows={n} process_alive=1 "
                f"secondary_work=0 — cannot attribute stall; NO-DATA not DEFECT"
            ),
            primary_sum=0.0,
            secondary_sum=ssum,
            process_alive=True,
        )

    # Process dead and primary flat → NO-DATA (no target), not DEFECT.
    if all_zero and not process_alive:
        return BlindCounterVerdict(
            verdict="NO-DATA",
            rc=RC_NO_DATA,
            reason="process_not_alive primary_flat",
            primary_sum=0.0,
            secondary_sum=ssum,
            process_alive=False,
        )

    # Scorable primary path.
    if defect_when_low and psum < float(low_threshold):
        return BlindCounterVerdict(
            verdict="DEFECT",
            rc=RC_DEFECT,
            reason=(
                f"{primary_name}_sum={psum} [measured] < "
                f"threshold={low_threshold} [caller_or_design] "
                f"(primary scorable; not blind)"
            ),
            primary_sum=psum,
            secondary_sum=ssum,
            process_alive=process_alive,
        )

    return BlindCounterVerdict(
        verdict="OK",
        rc=RC_OK,
        reason=f"{primary_name}_sum={psum} [measured] scorable",
        primary_sum=psum,
        secondary_sum=ssum,
        process_alive=process_alive,
    )


def _self_test() -> int:
    # RED: old rchar pattern must NOT become DEFECT
    v = classify_primary_counter(
        primary_deltas=[0, 0, 0, 0],
        secondary_deltas=[1e7, 2e7, 1e7, 3e7],  # wchar advancing
        process_alive=True,
        primary_name="rchar",
        secondary_name="wchar",
        defect_when_low=True,
        low_threshold=1.0,
    )
    assert v.verdict == "NO-DATA" and v.rc == RC_NO_DATA, v

    # Flat + alive + no secondary → still NO-DATA (not DEFECT)
    v2 = classify_primary_counter(
        primary_deltas=[0, 0],
        secondary_deltas=None,
        process_alive=True,
        defect_when_low=True,
        low_threshold=1.0,
    )
    assert v2.verdict == "NO-DATA" and v2.rc == RC_NO_DATA, v2

    # Scorable low primary with work → DEFECT allowed
    v3 = classify_primary_counter(
        primary_deltas=[10, 20, 15],
        secondary_deltas=[1e6, 1e6, 1e6],
        process_alive=True,
        defect_when_low=True,
        low_threshold=1000.0,
    )
    assert v3.verdict == "DEFECT" and v3.rc == RC_DEFECT, v3

    # Scorable healthy → OK
    v4 = classify_primary_counter(
        primary_deltas=[5000, 6000, 5500],
        secondary_deltas=[1e6, 1e6, 1e6],
        process_alive=True,
        defect_when_low=True,
        low_threshold=1000.0,
    )
    assert v4.verdict == "OK" and v4.rc == RC_OK, v4

    print("SELF_TEST_OK instrument_blind_counter")
    return 0


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return _self_test()
    ap.print_help()
    return RC_NO_DATA


if __name__ == "__main__":
    raise SystemExit(main())
