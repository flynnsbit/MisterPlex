# Parent card — standard vertical-RESOLUTION instrument (dominant pitch)

**Tool:** `tools/hdmi_vertical_pitch.py`  
**Branch:** `w-avsync-hdmi-measure`  
**Why:** Amplitude (STD / mean|d/dy| / adj_identical) **cannot** separate 240 vs 480 store (rd-review: Arm A STD 68.37 vs Arm B 67.75). Settling metric is **dominant vertical pitch** on rk=27 left 1-row-alt: upscaling cannot create spatial frequency.

Companion zone scorer (SOLID/STRIPES + mid/chirp): `tools/hdmi_fullbleed_vres_zones.py`.

Agent does not touch the device.

## Improvements vs throwaway FFT

| # | Requirement | Implementation |
|---|-------------|----------------|
| 1 | Pitch + **error bar** | zero-pad FFT (`pad=16`) + parabolic peak; ACF first peak near FFT; `pitch_err_rows`, `resolvable_delta_rows=P²/(2n)`; rejects min=max fake precision |
| 2 | **peak_share** / low coh → UNSCORED | unpadded fundamental lobe / total AC power; default min 0.12 (Arm A ~0.22 OK; Arm B ~0.046 suppressed) |
| 3 | Content zones + **deterministic bbox** | first/last signal + fixed close_rad; equal-thirds body + valley snap; `--ref-bbox` / `--lock-ref-bbox` for arm A/B |
| 4 | Red-before-green | synth 480 → pitch≈4.50 (full-bleed 1080 fit) / glass letterbox ≈3.99; 240 line-double → ≈9.0; 475 vs 480 honesty |

## Host evidence (`true rc` direct, no pipe)

```text
SELF_TEST_OK
QUOTE true rc full_expect480=0 half_expect480=3
self true rc=0

pitch_full480.png  --expect-pitch-480  → PITCH_480_OK rc=0  pitch≈4.501 ±0.125  peak_share≈0.83
pitch_half240.png  --expect-pitch-480  → STRUCTURE_FAIL rc=3 pitch≈8.999 (240-class under 480 expect)
pitch_half240.png  --expect-pitch-240  → PITCH_240_OK rc=0
unstamped                              → rc=77

475 vs 480 pure n=960: meas 4.0000±0.0083 vs 4.0377±0.0085
  delta=0.0377 > resolvable=0.0083, CI non-overlap → CAN_RESOLVE on pure SNR
  HONEST: live MJPG will be harder; if err bars overlap → report CANNOT_RESOLVE
```

```bash
python3 tools/hdmi_vertical_pitch.py --self-test
echo "true rc=$?"   # must be 0
```

## Capture + score (parent)

```bash
fuser -v /dev/video0; echo "true rc=$?"
tools/avsync_stamp_artifacts.sh > .agent-work/w-instr/stamp_live.json
echo "true rc=$?"

OUT=.agent-work/w-instr/pitch_glass_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
# play rk=27; grabber warm-up: discard first 15
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 40 -y "$OUT/f_%03d.png"
echo "true rc=$?"

# PRE-REGISTER: RBF 8fdf440f (480 path) → pitch ~3.99–4.5, peak_share ≳0.12, rc=0
#              old ceiling RBF → pitch ~8 or SOLID/low-share; under --expect-pitch-480 → rc=3
FRAME=$OUT/f_020.png   # skip flash whites

python3 tools/hdmi_vertical_pitch.py "$FRAME" \
  --expect-pitch-480 \
  --stamp-json .agent-work/w-instr/stamp_live.json \
  --decode-src caller_supplied \
  --json-out "$OUT/pitch.json"
echo "true rc=$?"

# Arm A/B fair crop (if auto bbox drifted 1230×955 vs 1237×958):
# 1) record bbox from arm A JSON active_bbox_xyxy
# 2) score arm B with --ref-bbox x0,y0,x1,y1 --lock-ref-bbox
```

### Headline fields (every value tagged)

- `pitch_rows` **measured** + `pitch_err_rows` **derived**
- `peak_share` **measured** (unpadded lobe/AC) — low → UNSCORED, not a fake pitch
- `resolvable_delta_rows` **derived** — true bin-limit honesty
- `predict_pitch_480` / `predict_pitch_240` / `predict_pitch_475` **derived** from body_h
- `active_bbox_xyxy` **measured** — pure function of pixels + fixed thresholds

### Expect gates

| Flag | PASS | FAIL (rc=3, never decays to 77) |
|------|------|----------------------------------|
| `--expect-pitch-480` | pitch ∈ [3.5, 4.8] | pitch ~8–9, SOLID, or low-coh suppressed |
| `--expect-pitch-240` | pitch ∈ [7.0, 9.6] or SOLID left | pitch ~4 |

### Bbox drift (rd-review open point)

Detector is **deterministic** on identical pixels. Different bbox across RBFs means **different pixels** (scale/timing), not RNG. Use `--ref-bbox` + `--lock-ref-bbox` so arms score the same crop; tool prints `BBOX_DRIFT` when auto disagrees.

## Severity

`STRUCTURE_FAIL 3 > COLOR_FAIL 2 > FREEZE 1 > OK 0 > UNSCORED 77`  
Measured miss under expect → 3. Setup/no-pair → 77. Empty ≠ zero.

## Missed predictions published

| Prediction | Result |
|------------|--------|
| Pad-diluted single-bin share matches parent 0.22 | **MISS** — use unpadded lobe/AC |
| Naive even-row copy of P=2 → pitch 7.98 | **MISS** — that is SOLID/DC; true 240 path is line-double of 240 unique |
| Full-bleed 1080 fit pitch = 3.99 | **MISS** — scale 2.25 ⇒ 4.50; 3.99 is letterboxed body ~960 |
