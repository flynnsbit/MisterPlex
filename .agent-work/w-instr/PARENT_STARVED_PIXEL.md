# PARENT CARD — STARVED from pixels (w-instr)

Branch: `w-instr-provenance`
SHA: 1da740dbfece0d2aa7fc3d54dfbe8d9edab53f3b

## Deliverables

### A — Provenance (ERROR 17) — already shipped, still green
Every rate field tagged `measured` | `caller_supplied` | `caller_supplied_measured` | `DEFAULT_ASSUMED`.
`--capture-fps-src` honored on PNG path. RATE_OK never on assumed fps.
`--strict-fps` refuses MOTION_OK when fps assumed; **preserves STARVED/STRUCTURE/COLOR/RATE/FREEZE** (fail never → 77).

### B — STARVED (first-class) — NEW
- `RC_STARVED = 5`, verdict `STARVED`
- Severity: **STRUCTURE > COLOR > STARVED > RATE_FAIL > FREEZE > OK > UNSCORED(77)**
- Why STARVED above RATE_FAIL: link/bitrate starvation is the user-visible class this session; bank-swap revisits stay RATE_FAIL.
- Why above FREEZE: pinned counter is FREEZE; slow but advancing is STARVED (distinct mechanisms).
- Positive fail never decays to 77.

#### Pre-register (LOCKED before measure)
```
STARVED iff:
  fps_authoritative
  AND counter advances (ctr_span>0, unique_states>=2)
  AND (
    endpoint_rate < STARVE_RATIO * expected
    OR unique_ratio < STARVE_ratio * expected
    OR delivered_fps < STARVE_RATIO * source_fps
  )
  AND NOT revisit_fail
STARVE_RATIO = 0.55 [DEFAULT_ASSUMED design]
expected = source_fps / capture_fps   # both labelled
```
- Score vs **source** rate — never retune to delivered.
- ~11 fps on 24.000 source (0.46×) = **TRUE POSITIVE**.
- Plateau mass `{4,5}` at 24@60 (~13 fps) is STARVED-class, not FREEZE.
- Pinned counter → STARVED cleared; motion FREEZE owns it.

### C — Colour B7 — already shipped
green/chroma/MAGENTA/BLUE/GREYSCALE/UV_SWAP/RED_BAR_MISSING. cap480a still COLOR+STRUCTURE.

## Red-before-green (direct `true rc`, no pipe)

### Synthetic / score_counter_pairs
```
HEALTHY  verdict=MOTION_OK rc=0 rate=RATE_OK starved=False delivered≈24.4
STARVED  verdict=STARVED   rc=5 rate=STARVED starved=True  delivered≈9.78
FREEZE   verdict=FREEZE    rc=1 rate=RATE_PINNED starved=False
ASSUMED  rate=RATE_UNSCORED starved=False (not STARVED on guess)
REVISIT  verdict=RATE_FAIL rc=4
SELF_TEST_OK true rc=0
INTEGRATION_STARVED_RBG_OK true rc=0
```

### Real captures (authoritative fps labelled)
```
python3 tools/hdmi_motion_instrument.py DIR \
  --source-fps 24.0 --source-fps-src caller_supplied_measured \
  --capture-fps 30.0 --capture-fps-src measured --json \
  > .agent-work/w-instr/starved_rbg/NAME.json
echo "true rc_$NAME=$?"
```

| capture   | verdict        | true rc | starved | delivered_fps | notes |
|-----------|----------------|---------|---------|---------------|-------|
| cap480b   | MOTION_OK      | 0       | False   | 24.0          | good 480p |
| cap240fs  | MOTION_OK      | 0       | False   | 23.85         | good 240p |
| long      | MOTION_OK      | 0       | False   | 23.39         | RK3 |
| cap480a   | STRUCTURE_FAIL | 3       | False   | —             | bank desync; structure wins |

No archived glass STARVED burst on host this turn — synthetic half-rate RBG proves detector both directions. Parent: hand starved capture paths when available for glass confirm.

## Exact commands for parent (device run)

720p60 preferred (MS2109: 1080p caps 30; 720p has 60):
```bash
fuser -v /dev/video0   # must be free
mkdir -p CAP_rk9_720p60
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
  -i /dev/video0 -frames:v 540 -y CAP_rk9_720p60/f_%03d.png
echo "true rc_cap=$?"

python3 tools/hdmi_motion_instrument.py CAP_rk9_720p60 \
  --source-fps 24.0 --source-fps-src caller_supplied_measured \
  --capture-fps 60.0 --capture-fps-src measured \
  --warmup-skip 15
echo "true rc_score=$?"

# Judder companion (hold histogram) — separate instrument
python3 tools/glass_motion_judder.py CAP_rk9_720p60 \
  --source-fps 24.0 --capture-fps 60 --capture-fps-src measured \
  --floor-json .agent-work/w-instr/floor_capture_timing.json \
  --precheck-only
echo "true rc_pre=$?"
```
Pre-register 24@60 healthy holds `{2,3}`; ~13 fps delivered → mass `{4,5}` TRUE POSITIVE judder fail / STARVED on counter rate.

## Still open
- Content-dup instrument floor: **not separable without HDMI re-cable** (accepted).
- `device_attributable=False` for content-hold until content floor.
- Colour beyond green already green; keep as second priority evidence.
