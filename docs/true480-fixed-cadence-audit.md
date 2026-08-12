# True-480 fixed-cadence audit

This is a source-only, pre-fit audit. The native beam contract supplied for
true-480 is:

```text
20,000,000 / (2 * 672 * 496)
  = 78,125 / 2,604
  = 30.001920122887864 Hz
```

One beam frame is exactly 666,624 system-clock cycles or 33.3312 ms.

## Current presentation contracts

- `frameContentMs()` schedules decoded frames from the exact source rational,
  but returns integer milliseconds.
- Video pacing uses `audibleClockMs()`, which subtracts the measured MrAudio
  queue from submitted bytes. A stable queue therefore changes fixed offset,
  not clock rate.
- `avDecide()` presents inside the 40 ms lead window and drops only when a
  frame is over 80 ms late. Recovery is capped at one consecutive host drop.
- A host frame-store request becomes visible on `frame_start`/VSync. The
  legacy integer `present_cadence` result animates generated bars and does not
  gate product frame-store swaps.

## Ideal exact-rational beam cadence

| Source | Unique source frames | Beam ticks | Repeats | Beam drops | Exact cycle |
|---|---:|---:|---:|---:|---:|
| 24000/1001 | 71,424 | 89,375 | 17,951 | 0 | 2,978.976 s |
| 24 | 62,496 | 78,125 | 15,629 | 0 | 2,604 s |
| 25 | 2,604 | 3,125 | 521 | 0 | 104.16 s |
| 30000/1001 | 17,856 | 17,875 | 19 | 0 | 595.7952 s |
| 30 | 15,624 | 15,625 | 1 | 0 | 520.8 s |

For exact release times, all sources are slower than the beam, so the beam only
holds/repeats frames. Phase error is a bounded sawtooth below one beam period;
it does not accumulate against the audible clock.

## Current integer-millisecond host schedule

`test_fixed30_host_pacing` uses the production clock helpers and maps each host
frame's earliest eligible integer-millisecond release to the first native-beam
VSync. Runtime 2 ms polling and scheduler/copy jitter can rotate or perturb the
pattern; this model tests whether the host timing contract guarantees one
source frame per VSync opportunity. At beam phase zero:

| Source | Host schedule cycle | Duration | Same-tick source frames | Two-tick gaps | Net duplicates |
|---|---:|---:|---:|---:|---:|
| 24000/1001 | 71,424 frames | 2,978.976 s | 0 | 17,951 | 17,951 |
| 24 | 62,496 frames | 2,604 s | 0 | 15,629 | 15,629 |
| 25 | 2,604 frames | 104.16 s | 0 | 521 | 521 |
| 30000/1001 | 89,280 frames | 2,978.976 s | 563 | 658 | 95 |
| 30 | 15,624 frames | 520.8 s | 103 | 104 | 1 |

The near-30 rates expose a pre-fit risk hidden by average-rate accounting.
Integer-millisecond timestamps contain 33 ms intervals, shorter than the
33.3312 ms beam. Two host frames can therefore target the same VSync, followed
later by a two-tick gap. Several deterministic beam-phase probes retain this
collision class. `avDecide()` reports these frames as normal `Present`, not
recovery `Drop`; whether the first pending frame is superseded depends on the
frame-store/doorbell timing. The opportunities are clustered rather than
uniform: phase zero groups the 30000/1001 events into 95 correction clusters
over 2,978.976 s (about 31.36 s apart), while 30 fps puts its 103/104
same-/two-tick pairs into one roughly 10.2 s cluster per 520.8 s cycle.

This is a blocker for claiming clean 30000/1001 or 30 fps glass cadence from
source inspection alone. Resolving it requires either finer-than-millisecond
host release timing or a proven one-pending-frame/VSync acknowledgement policy,
then external capture. This audit does not change production timing.

## 24p-class verdict

Both 24000/1001 and 24 fps avoid the same-VSync collision in the deterministic
model and remain bounded to the audible clock. They still alternate one- and
two-beam-tick holds (33.3312/66.6624 ms): fixed 30.0019 Hz cannot provide smooth
native 24p motion. It can remain free of monotonic audio drift only because the
host follows the exact rational schedule and inserts the long-run correction
repeats. A source-matched beam/runtime PLXG is required for uniform 24p motion.

## Gates and remaining evidence

Pre-fit gates:

```bash
python3 tests/unit/test_fixed30_cadence.py
build/test_fixed30_host_pacing
build/test_avclock
build/test_mraudio_status
make unit
```

Hardware remains parent-only. A product claim still requires a fitted RBF that
proves the 20 MHz divide-by-two, 672x496 timing and a paired HDMI-video/USB-audio
capture with provenance-bearing adapter-offset calibration. Missing audio is
BLOCKED, never PASS.
