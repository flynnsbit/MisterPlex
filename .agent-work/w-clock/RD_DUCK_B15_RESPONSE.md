# rd-duck B15/B13 adversarial response (w-clock)

## Accepted findings → fixes

| Finding | Fix | Proof |
|---------|-----|-------|
| framecount called raster "unique" | Honest `frame_start` / `swap_opp`; ban unique-bank claim | GREEN log string |
| cadence display_hz=60 vs core 24/30 | BEAM_960 `cadence_display_hz` = 24/30 from film class | RED HDMI60: 3 adv / 5 raster |
| advance unused for DDR swap | Documented C1: swap = fstart&&swap_pending | NOTE in TB |
| 25 fps → 24.0007 film | film = `fps<=24` only; >=25 → V=564 | GREEN fps=25 |
| 25 @ core 30 advance rate | floor(n*25/30) → 4/5 advances (hold) | GREEN adv=4 |
| present_core whole-file merge | PRESENT_CORE_MERGE_NOTE.md | manual merge w/ w-mem B16 |

## Claim limits
- `swap_opp` with pending held high = fabric upper bound on swaps, **not** ARM unique-bank proof.
- Unique content banks need parent/device or store cosim with real publish traffic.

## rd-duck follow-up: 25fps is NOT 1:1

Accepted. Design keeps **25 → TV raster 30** (V=564), not a ~25 Hz V_TOTAL.

| Window | raster | advances | math |
|--------|--------|----------|------|
| short (5 TV frames) | 5 | **4** | di 0,2,3,4 |
| long (30 TV frames) | 30 | **25** | floor(n·25/30) over n=0..29 |

`content_fps == cadence_display_hz` only for 24 and 30. Comments/tests no longer claim 1:1 for 25.
