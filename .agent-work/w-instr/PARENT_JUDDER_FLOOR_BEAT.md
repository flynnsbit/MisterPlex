# PARENT CARD — glass judder: instrument floor + beat (BLOCKING) — w-instr

**Branch:** `w-instr-provenance`  
**Question answered:** *is motion delivery uniform?* (NOT lipsync; NOT 480p “looks like 240” — already explained by pitch).

## Status (honest)

| Item | State |
|---|---|
| Synthetic RBG hold + IFI | **DONE** — recovers N=5 long holds; IFI max 200 ms on RED |
| Beat / quant model 24@30 | **DONE** — commensurate 5/4; **reject** `T_cap/√12` |
| Host floor **fixture** | **DONE** — exact 24.000 CFR mp4 (`ffprobe r_frame_rate=24/1`) |
| MS2109 floor **capture** | **PARENT MUST RUN** — agent does not touch `/dev/video0` |
| Device attribution | **BLOCKED** until floor JSON exists — all prior device hist tagged `device_attributable=False` |

**Until floor capture exists, do not publish any device motion number as product truth.**

## A. Beat / quantisation (locked, no device needed)

```
source_fps=24.000 [caller_supplied_measured]
capture_fps=30.000 [caller_supplied]   # lab MJPEG burst rate
t_src_ms=41.6667  t_cap_ms=33.3333
ratio cap/src = 5/4  commensurate=True
pattern_period = 5 capture frames = 4 source frames = 166.667 ms
discrete IFI on capture grid = {33.333, 66.667} ms  (mean 41.667)
drop signature IFI ≈ 83.333 ms → lands as hold≥3 → IFI≥100 ms on grid
continuous_quant_rms_ms = T_cap/√12 = 9.6225  → usable=False
```

**Plain statement:** 24.000 and 30.000 **do beat as a locked 4:5 rational**, not a slow incommensurate wander. Healthy presentation through a 30 Hz sampler is a **two-point mass** on holds `{1,2}` / IFI `{33.3,66.7}`.  
**`33/√12` is the wrong floor** for any quadrature subtraction here — rd-review flag confirmed in code (`continuous_quant_rms_usable=False`).

Command:
```bash
cd .worktrees/w-instr-provenance
python3 tools/glass_motion_judder.py --beat-only \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied; echo "true rc=$?"
```

## B. Instrument-floor control — PARENT RUNBOOK (do this FIRST)

### B0. Emit fixture (host, already done once; re-run anytime)
```bash
cd .worktrees/w-instr-provenance
python3 tools/glass_motion_judder.py \
  --emit-floor-fixture .agent-work/w-instr/floor_fixture; echo "true rc=$?"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=r_frame_rate,avg_frame_rate,nb_frames,duration \
  -of default=nw=1 .agent-work/w-instr/floor_fixture/cadence_24.000.mp4
# expect r_frame_rate=24/1  nb_frames=240  duration=10
```

### B1. CADENCE FLOOR (host-generated exact 24.000 → display → MS2109 → ffmpeg)
**Source is NOT the DE10-Nano.**

```bash
fuser -v /dev/video0   # must be free; exclusive MS2109

# On the monitor that feeds the grabber HDMI input:
mpv --fs --no-osc --loop=no \
  .worktrees/w-instr-provenance/.agent-work/w-instr/floor_fixture/cadence_24.000.mp4

# Concurrently on the lab host:
mkdir -p /tmp/floor_cap_cadence
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 120 -y /tmp/floor_cap_cadence/f_%03d.png
echo "true rc=$?"   # DIRECT — never through a pipe

cd .worktrees/w-instr-provenance
python3 tools/glass_motion_judder.py /tmp/floor_cap_cadence \
  --role instrument_floor --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied \
  --label floor_cadence_host \
  --json > .agent-work/w-instr/floor_cadence.json
python3 tools/glass_motion_judder.py /tmp/floor_cap_cadence \
  --role instrument_floor --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied \
  --label floor_cadence_host; echo "true rc=$?"
```

**Pre-register floor (before you look at hist):**
- Expect hold mass mostly `{1,2}` if grabber+host preserve cadence.
- Publish **full hist + p50/p95/p99/max + outlier_count** — never max-only.
- That tail **is** the instrument envelope. Verdict should be `FLOOR_OK` or `FLOOR_IRREGULAR` (not product JUDDER_*).

### B2. STATIC FLOOR (grabber dup/noise only)
```bash
# Pause mpv on one frame OR fullscreen static_frame.png
mkdir -p /tmp/floor_cap_static
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 90 -y /tmp/floor_cap_static/f_%03d.png
echo "true rc=$?"

python3 tools/glass_motion_judder.py /tmp/floor_cap_static \
  --role instrument_floor --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied \
  --label floor_static; echo "true rc=$?"
```
Static should show near-zero content changes (or UNSCORED if blind). Any “motion” here is **grabber/encode**, not device.

### B3. DEVICE only after floor JSON
```bash
python3 tools/glass_motion_judder.py /tmp/cap480b \
  --role device_under_test \
  --floor-json .agent-work/w-instr/floor_cadence.json \
  --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied \
  --label 480p; echo "true rc=$?"
# device_attributable=True only if floor present; exceeds floor if tail >> floor
```

Attribution rule (pre-registered): device exceeds floor if  
`outlier_count >= floor_outliers+3` OR `hold_max >= floor_max+2`.

## C. Synthetic red-before-green (agent, done)

```
GREEN hold_hist={1:24,2:24} ifi={33.3:24,66.7:24} frac_ge_drop=0 → JUDDER_OK rc=0
RED   5×hold6 → outliers=5 ifi max=200ms frac_ge_drop=0.104 → JUDDER_FAIL rc=2
FLOOR_ROLE → FLOOR_OK device_attributable=False
DEVICE no floor → device_attributable=False
SELF_TEST_OK true rc=0
```

## D. Existing device bursts — MEASURED but NOT ATTRIBUTABLE

| capture | hold_hist | ifi_ms hist | p50/p95/p99/max ifi | outliers | verdict | rc | attributable |
|---|---|---|---|---|---|---|---|
| cap480b | {1:45,2:15} | {33.3:45,66.7:15} | 33.3/66.7/66.7/66.7 | 0 | JUDDER_OK | 0 | **False** (no floor) |
| cap240fs | same | same | same | 0 | JUDDER_OK | 0 | **False** |
| long | {1:109,2:38} | {33.3:109,66.7:38} | 33.3/66.7/66.7/66.7 | 0 | JUDDER_OK | 0 | **False** |
| cap480a | {2,3,4,5} | {66.7,100,133,166} | 100/133/160/167 | 10 | JUDDER_FAIL | 2 | **False** |

Pixel histograms are real. **Product causal claim is forbidden until B1 floor runs.**

## E. Tools
- `tools/glass_motion_judder.py` — holds + IFI_ms + beat + role/floor
- `tools/glass_motion_beat_ifi.py` — beat + IFI helpers
- Prior colour/OCR instrument unchanged

## F. Out of scope (do not fold in)
- Lipsync / flash↔beep (w-avsync)
- “Didn’t look like 480p” vertical pitch (done on `8fdf440f`)
- Daemon drops_delta / publishMisses_ / av-lock string (ERROR 20; wrong counters)

## G. Self-test
```bash
cd .worktrees/w-instr-provenance
python3 tools/glass_motion_judder.py --self-test; echo "true rc=$?"
```
