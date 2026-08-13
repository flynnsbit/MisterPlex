# True-480 fixed-cadence audit

This is a source-only, pre-fit audit. The native beam contract supplied for
true-480 is:

```text
20,000,000 / (2 * 672 * 496)
  = 78,125 / 2,604
  = 30.001920122887864 Hz
```

One beam frame is exactly 666,624 system-clock cycles or 33.3312 ms.

## Actual product path

True-480 product playback uses `pipelineDdr`: FFmpeg writes YUV420p frames to a
large pipe, a reader fills a two-slot cached ring, and a presentation thread
copies a slot to DDR and rings the doorbell. With audio active, the reader does
not use `frameContentMs()` pacing. `audioPump()` wall-paces 48 kHz audio and its
backpressure normally rate-limits FFmpeg, but buffered video and the two slots
still permit decoded-frame bursts.

The previous source-only audit incorrectly treated the integer-millisecond
reader schedule as the product gate. The real pre-fix hazard was independent:
`sendDdrFrame()` polled PLXD zero times and, while `swap_pending`, immediately
selected `disp_bank ^ 1`. That is the pending bank. A second buffered frame
could therefore replace a frame before VSync.

## Source-side guarantee

Exact true-480 geometry now enables two coupled gates:

1. Each ring slot carries its CFR frame index. The presentation thread releases
   it from `frameContentUs(index, fpsNum, fpsDen)` against
   `audibleClockUs(written, queued)` (or a monotonic microsecond wall clock when
   audio is unavailable). The existing 40 ms lead, 80 ms late-drop threshold,
   and maximum one consecutive recovery drop are unchanged.
2. `DdrBankWritePolicy::RequireReleased` requires a valid PLXD
   `free_bank_mask` before the first DDR payload copy. Immediately after its
   kick, the host captures a stable 16-bit `frames_done` baseline; while that
   post-kick baseline is unknown, no further strict write is eligible. Every
   later strict write requires both a free bank and a different `frames_done`
   value, including a wrapped value, proving the immediately prior doorbell
   crossed VSync rather than trusting a stale free mask. Sampling after the
   kick also prevents a VSync during the payload copy from being misclassified
   as its acknowledgement. It waits at most 50 ms. Missing/stale PLXD or a
   timeout aborts the true-480 pipeline instead of reusing the pending bank.
   Reset, DDR reprobe, and layout/remap changes clear the per-instance
   baseline. Legacy, diagnostic, and 720 paths retain their prior best-effort
   behavior.

A strict-send failure aborts true480 presentation and is carried through
teardown as a distinct pipeline failure. It reports `stopped`, never natural
`ended`, so a mid-title PLXD failure cannot silently trigger auto-next.

Thus a buffered burst cannot bypass source-rate eligibility, and an eligible
catch-up frame cannot supersede a still-pending frame. A product RBF must
publish the existing PLXD bank-release mailbox; absence fails closed.

## Exact-rational beam cadence

| Source | Unique source frames | Beam ticks | Repeats | Beam drops | Exact cycle |
|---|---:|---:|---:|---:|---:|
| 24000/1001 | 71,424 | 89,375 | 17,951 | 0 | 2,978.976 s |
| 24 | 62,496 | 78,125 | 15,629 | 0 | 2,604 s |
| 25 | 2,604 | 3,125 | 521 | 0 | 104.16 s |
| 30000/1001 | 17,856 | 17,875 | 19 | 0 | 595.7952 s |
| 30 | 15,624 | 15,625 | 1 | 0 | 520.8 s |

Every required source is slower than the beam. Exact eligibility therefore
produces only one- or two-beam-tick holds: no two source frames target the same
beam tick. Microsecond timestamp truncation stays below 1 us and forms a
bounded sawtooth rather than monotonic drift. A stable MrAudio queue depth
changes fixed A/V offset, not rate, because the audible clock subtracts the
queued byte count.

`test_fixed30_host_pacing` explicitly proves:

- the old unpaced/best-effort two-slot sequence permits a pending-bank
  supersede (RED);
- exact eligibility holds the second burst frame;
- strict PLXD refuses both a busy mailbox and a stale unchanged-`frames_done`
  free mask, then accepts only after `frames_done` advances with a free bank;
- all five rational rates have the exact repeat counts above; and
- sustained late recovery never drops two consecutive frames.

## 24p-class verdict

`24000/1001` and 24 fps can remain bounded to the audible clock without
long-run A/V rate drift. They cannot have uniform motion on a fixed
30.001920 Hz beam: the unavoidable one-/two-tick hold pattern is
33.3312/66.6624 ms judder. Runtime PLXG or another source-matched display rate
is still required for smooth native 24p motion.

## Gates and remaining evidence

Pre-fit gates:

```bash
python3 tests/unit/test_fixed30_cadence.py
build/test_fixed30_host_pacing
build/test_avclock
build/test_mraudio_status
build/test_input_mailbox
python3 tests/unit/test_av_logging_contract.py
make unit
make arm-plexd
```

Hardware remains parent-only. A product claim still requires a fitted RBF that
proves the 20 MHz divide-by-two, 672x496 timing and functioning PLXD release,
then a paired HDMI-video/USB-audio capture with provenance-bearing
adapter-offset calibration. Missing audio or PLXD acknowledgement is BLOCKED,
never PASS.
