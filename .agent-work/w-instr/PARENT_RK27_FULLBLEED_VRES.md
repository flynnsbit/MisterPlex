# Parent card — rk=27 FullBleed VRes zone scorer (RBF `8fdf440f`)

**Tool:** `tools/hdmi_fullbleed_vres_zones.py` (SOLID/STRIPES + mid/chirp zones)  
**PRIMARY V-res metric (pitch + err + peak_share):** `tools/hdmi_vertical_pitch.py` — see `PARENT_VERTICAL_PITCH.md`  
**Branch:** `w-avsync-hdmi-measure`  
**Agent does not touch the device.** Parent runs capture + stamps.

**Note:** Amplitude (STD) does not separate 240 vs 480. Prefer pitch instrument for the resolution claim; this zone tool remains the P=2 SOLID collapse + multi-zone report.

## Why this exists

Ad-hoc scorers failed on glass:
- idle-logo row-pair → byte-identical across bitstreams (blind)
- run-length on blip → content-dominated

This scorer is **zone-resolved** against w-asset480 fixture rk=27  
(`MiSTerPlex Bank480 FullBleed VRes AV 624x480 24fps 1200s`):

| Zone | Designed | Ceiling role |
|------|----------|--------------|
| **left** 1-row B/W | P=2 | **PRIMARY** — STRIPES (480) vs SOLID (even-row ceiling) |
| mid stacked | P=2/4/8/16 | P=2 secondary; **P≥4 duty-50 invariant under even-cull — NOT gates** |
| right chirp | 2→32 | **NOT a ceiling gate** (INSTRUMENT_CEILING) |

## Host red-before-green (quoted)

```text
SELF_TEST_OK
QUOTE true rc full_expect480=0 half_expect480=3
self true rc=0

host glass_sim_f100.png     --expect-full-480     true rc=0   H480_STRIPES_OK left=STRIPES ratio≈1.03
host glass_sim_even_dup.png --expect-full-480     true rc=3   STRUCTURE_FAIL_SOLID_UNDER_EXPECT_480 left=SOLID
host glass_sim_even_dup.png --expect-ceiling-240  true rc=0   H240_SOLID_OK
unstamped                                             true rc=77
```

Self-check anytime:

```bash
python3 tools/hdmi_fullbleed_vres_zones.py --self-test
echo "true rc=$?"    # must be 0
```

## Capture (parent, after warm-up)

`/dev/video0` exclusive. Discard first 15 frames (grabber warm-up). Empty = NO-DATA never zero.

```bash
fuser -v /dev/video0; echo "true rc=$?"
# if busy: close holders; do not score zeros

STAMP_DIR=.agent-work/w-instr
tools/avsync_stamp_artifacts.sh > "$STAMP_DIR/stamp_live.json"
echo "true rc=$?"
cat "$STAMP_DIR/stamp_live.json"
# need full 32-hex rbf_md5 + daemon_md5; decode_src from log if known

OUT=.agent-work/w-instr/rk27_glass_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
# play rk=27 asset on device first (parent)
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 40 -y "$OUT/f_%03d.png"
echo "true rc=$?"
# score from frame index 15 onward (warm-up)
ls "$OUT"/f_*.png | wc -l
```

Skip flash frames (full white every 2 s) — tool returns UNSCORED for those.

## Score one frame (stamped)

**PRE-REGISTER before looking:**

| RBF hypothesis | expect flag | PASS |
|----------------|-------------|------|
| 480 unique rows reach glass | `--expect-full-480` | left `STRIPES`, rc=0 `H480_STRIPES_OK` |
| even-row ceiling still live | `--expect-ceiling-240` | left `SOLID`, rc=0 `H240_SOLID_OK` |
| wrong expect | opposite | rc=3 STRUCTURE_FAIL (never decays to 77) |

```bash
# Prefer a non-flash body frame after warm-up, e.g. f_020
FRAME=$OUT/f_020.png

python3 tools/hdmi_fullbleed_vres_zones.py "$FRAME" \
  --expect-full-480 \
  --stamp-json .agent-work/w-instr/stamp_live.json \
  --decode-src caller_supplied \
  --json-out "$OUT/vres_zones.json"
echo "true rc=$?"

# Headline fields (all tagged measured|caller_supplied|DEFAULT_ASSUMED|derived):
#   left_p2 = STRIPES|SOLID
#   left_ratio_period = period_src/designed (NO-DATA when SOLID / below noise floor)
#   left_unique_frac  = profile uniqueness (upscale → ~0.44 full stripes; ~0 solid)
#   mid P4/8/16 ratio ~1.0 even under ceiling (invariant — do not use as gate)
```

Unstamped path must refuse:

```bash
python3 tools/hdmi_fullbleed_vres_zones.py "$FRAME" --expect-full-480
echo "true rc=$?"   # 77
```

## How zones are located (no hardcoded 1920 columns)

1. **Active region** — first/last rows&cols with mean/std signal (gap-tolerant). Fail → UNSCORED.
2. **ID band** — drop top glass counter plate (measured edge or DEFAULT 88/480).
3. **L/M/R** — equal thirds of **measured active body width**, optional snap to local column-energy valley within ±8%. Energy-only cumulative thirds are **void** when left is solid (swallow mid). Width fail → UNSCORED.

## Noise floor

`profile_std < noise_floor_std` (default 8.0, caller_supplied) → zone spectrum **UNSCORED**  
(reason states NO-DATA, not "no stripes"=0). SOLID class still drives ceiling expect.

## Severity

`STRUCTURE_FAIL 3 > COLOR_FAIL 2 > FREEZE 1 > OK 0 > UNSCORED 77`  
Measured fail never decays to 77. Empty/missing stamp/zone = 77 only.

## Optional: also run row-pair scorer on same frame

```bash
python3 tools/hdmi_vertical_unique_rows.py "$FRAME" \
  --expect-full-480 \
  --stamp-json .agent-work/w-instr/stamp_live.json
echo "true rc=$?"
```

## Missed predictions (publish)

| Prediction | Result |
|------------|--------|
| Energy-only thirds locate left under SOLID collapse | **MISS** — swallowed mid; fixed equal-third seed |
| unique_frac full ≈1.0 after 1080 NEAREST upscale | **MISS** — ~0.44 (multi-row runs); gate on std+STRIPES class |
| even_odd_sep alone classifies P=2 after upscale | **MISS** — period_disp≠2; use std/ptp/unique |
| mid P4 ratio halves under even-cull | **MISS (as designed)** — invariant ~1.0; not a ceiling gate |
