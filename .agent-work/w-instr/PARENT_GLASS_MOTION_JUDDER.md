# PARENT CARD — glass motion/judder instrument (w-instr)

## Why
User: "frames being dropped" / "480p didn't look like 480p". A/V phase is lipsync, not motion.
Daemon `drops_delta=0` while glass A/V wandered. No prior pixel instrument for hold/judder.
ERROR 20: daemon `" clock=av-lock"` is a string literal — self-report void. Viewed pixels only.

## Tool
`tools/glass_motion_judder.py` on branch `w-instr-provenance`

## Method (not md5)
1. Active-letterbox luma crop; pair-wise **block-max MAD** (16×16).
2. **Noise** from hold-like pairs only (`block_max_mad <= ABS_FLOOR=2`), never bottom-25% of all deltas
   (that mixed real counter motion into noise → false long holds; fixed after first RED real run).
3. `threshold = max(2.0, 6*noise_p99)`; change if block_max_mad > threshold.
4. Hold-duration histogram + **tail** (p50/p95/p99/max, outlier_count). Mean is informational only.
5. Every field tagged `measured` / `caller_supplied` / `DEFAULT_ASSUMED` / `caller_supplied_measured`.
6. Rate scoring refused without authoritative fps → UNSCORED rc=77 (never a pass).
7. Warmup skip default 15. Dark+blind change_frac → UNSCORED (ERROR 13), not FAIL.

## Pre-register (locked before measure) — 24 fps src @ 30 fps capture
- `ideal_hold = cap/src = 1.25` → healthy mass in holds `{1,2}` (3:2-style)
- `outlier_min = 4` (hold ≥4 capture frames ≈ ≥133 ms stall)
- FAIL if `outlier_count >= 3` OR `frac_ge_outlier >= 0.05` OR `max_hold >= 5`
- PASS needs authoritative fps, `n_holds >= 15`, and none of the FAIL conditions

## Synthetic red-before-green (`--self-test`)
```
GREEN  hist={1:24,2:24} outliers=0 → JUDDER_OK rc=0
RED    5× injected hold=6 → outliers=5 recovered → JUDDER_FAIL rc=2
UNSCORED assumed fps / black-blind → rc=77
SELF_TEST_OK true rc=0
```

## Real device captures (parent-owned; agent did not touch device)
| capture | hist | p50/p95/p99/max | outliers | VERDICT | true rc |
|---|---|---|---|---|---|
| `/tmp/cap480b` good 480p | `{1:45,2:15}` | 1/2/2/2 | 0 | JUDDER_OK | **0** |
| `/tmp/cap240fs` 240p control | `{1:45,2:15}` | 1/2/2/2 | 0 | JUDDER_OK | **0** |
| `/tmp/long` RK3 200f | `{1:109,2:38}` | 1/2/2/2 | 0 | JUDDER_OK | **0** |
| `/tmp/soak1` RK1 | `{1:43,2:16}` | 1/2/2/2 | 0 | JUDDER_OK | **0** |
| `/tmp/cap480a` broken/magenta | `{2:2,3:10,4:9,5:1}` | 3/4/4.79/5 | 10 | JUDDER_FAIL | **2** |

**Finding on these fixtures:** healthy 24@30 glass shows clean 3:2 hold mass only (mean≈1.25–1.27), **zero** hold≥4 outliers on good 480p and 240p. Motion quality is **not** tier-split on TREK24 fixtures in these bursts. Broken 480p path fails judder with long holds (incidental to structure defects).

## Grabber (MS2109) noise characterisation — `/tmp/cap480b`
- hold-like pairs: noise_p50=0 noise_p99=0 [measured] → threshold=2
- all-pair block_max: p50≈16.8 p99≈248 (content + flash)
- **Grabber does not inject measurable hold MAD noise** at this metric on known-good TREK24.
- Cadence defects (if any) on these fixtures are not grabber MAD floor.

## Exact commands (host only)
```bash
cd .worktrees/w-instr-provenance   # or checkout branch

python3 tools/glass_motion_judder.py --self-test; echo "true rc=$?"

python3 tools/glass_motion_judder.py /tmp/cap480b --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied \
  --label 480p; echo "true rc=$?"

python3 tools/glass_motion_judder.py /tmp/cap240fs --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied \
  --label 240p_control; echo "true rc=$?"
```

Capture for parent (device exclusive `/dev/video0`):
```bash
fuser -v /dev/video0   # must be free
mkdir -p OUT
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 90 -y OUT/f_%03d.png
# instrument discards first 15; need ≥~50 after warmup for n_holds≥15
```

## What this does NOT claim
- Does not measure lipsync (w-avsync).
- Does not use daemon drops/av-lock (void under ERROR 20).
- md5-distinctness never used (ERROR 8 + 13).
- Without measured/caller_supplied_measured src_fps → UNSCORED, not PASS/FAIL.

## Provenance payoff note (prior lane)
Daemon `output=DEFAULT_ASSUMED` on OSD — keep label until measured/ini (w-osd-hires). Do not soften.

## Colour B7 (second priority, already shipped `40c7d515`)
Magenta/red-bar/UV_SWAP etc. remain; this card is motion/judder primary.
