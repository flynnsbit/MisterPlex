# A/V + drop verdict — audio + telemetry (pixels optional)

## User request (verbatim)

> eventually you need to verify framerate and audio sync on the 480p path. in my
> testing it seems like there are frames being dropped.

## Parent silicon that reshapes the instrument (2026-08-02)

| case | supply_ratio | av_drift_ms | drops | notes |
|------|-------------:|------------:|------:|-------|
| HEALTHY | 0.988 | −22 | flat | |
| COLLAPSED | 0.599 | +56 | **1065** | frames=3316 pfps=9.73 |
| COLLAPSED | 0.824 | +81 | 619 | |

- **`av_drift_ms` climbs as supply falls** while the old `clock=av-lock` string was
  meaningless (hardcoded; removed). Drift is still **servo error**, not lipsync GT
  (`av_clock.hpp` / `AV_PRESENT_LEAD_MS` pin).
- **PMS Docker on the agent host** contaminates **transcode** runs
  (`complete=0 speed=0` vs healthy `complete=1 speed=19.8`). Prefer **direct-play**
  fixtures; always publish concurrent **host load**.
- HDMI grabber may be **pixel-blind** (`Pixelclock: 0 Hz`). Instrument must verdict
  from **audio + daemon telemetry**; pixels are confirmation when lock returns.

## Tool

`tools/avsync_audio_telemetry_verdict.py`

### What it settles

1. **supply_ratio** starvation (media line or reconstructed `Δaudio_s/Δwall_s`)
2. **drops vs publish_misses vs residual** with code semantics (below)
3. **Audio marker cadence** (1 kHz beep every `marker_period_s`, default 1.0)
4. Whether **av_drift_ms is climbing** during collapse (telemetry fact only)
5. **Content fps** from ffprobe of fixture (`measured`) and optional PMS
   `frameRate` (`caller_supplied`) — never a silent 23.976 default

### What it cannot settle (printed every run)

- Glass lipsync offset without flash↔beep **video** capture
- Visible judder / inter-frame histogram (**w-instr**)
- Path capacity vs local limiter (**w-cpu-1**)
- Device defect from a transcoder-starved cast (host-load confound)
- Using `av_drift_ms` as lipsync accuracy

## drops=1065 — code meaning (not a vibe)

| counter | increments | reset (this tree) | means |
|---------|------------|-------------------|-------|
| **`drops` / `droppedFrames_`** | `media_player.cpp` ~**:4183–4185** `if (!present) droppedFrames_.fetch_add(1)` after `avDecide` → **Drop** | play-path ~**:3010** `store(0)` | **Deliberate A/V-pacer skip** of `presentCleanFrame` |
| **`publish_misses` / `publishMisses_`** | ~**:3641** DDR/FPGA publish fail inside `presentCleanFrame` | play-path ~**:3011** | Present attempted; arm publish failed |
| **`residual`** | arithmetic | — | **`frames − presents − drops`** (`frame_ledger.hpp`) |

So **drops=1065** means the pacer chose Drop 1065 times. It does **not** mean
ffmpeg failed to produce 1065 frames, and it does not by itself prove glass
judder. If `residual==0` and `publish_misses==0`, every non-present was a pacer
Drop.

Parent citation fix: resets are **`:3010`/`:3011`**, not `:2312`/`:2432`
(silence-scan / ring).

## Fixture (direct-play 480p blip)

Same construction as `assets/avsync/sync_trekmatch_1080p24_blip.mp4`
(flash + 50 ms 1 kHz beep every 1.0 s, counter every frame):

```bash
python3 scripts/gen_avsync_blip.py --only trekmatch480 --duration 120
# → assets/avsync/sync_trekmatch_624x480_24_blip.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate \
  -of csv=p=0 assets/avsync/sync_trekmatch_624x480_24_blip.mp4
# expect: 624,480,24/1   fps_src=measured
```

Bitrate **1200k** so lab ~1.5 Mbit path can direct-play without the 2000 kbit/s
PMS floor forcing a starved transcode. **Do not** score A/V through a
`complete=0 speed=0` session.

Also usable: existing `sync_glass_av_480p24_600s.mp4` (marker period **2.0 s** —
pass `--marker-period-s 2`). Host red-before-green on the shipped +100 ms twin:

```bash
python3 tools/avsync_audio_telemetry_verdict.py \
  --audio assets/avsync/sync_glass_av_480p24_600s_audioPlus100ms.mp4 \
  --designed-offset-ms 100 --marker-period-s 2.0
echo "true rc=$?"   # expect DESIGNED_OFFSET_DETECT rc=6 (phase≈95–100 ms)

python3 tools/avsync_audio_telemetry_verdict.py \
  --audio assets/avsync/sync_glass_av_480p24_600s.mp4 \
  --designed-offset-ms 0 --marker-period-s 2.0
echo "true rc=$?"   # expect PASS rc=0
```

**Not** a 1 kHz blip grid: `sync_audio_id_*` (FSK frame ID). Do not score those
with `--marker-period-s 1` expecting beeps.

## Red-before-green (host, no device)

```bash
cd /path/to/worktree
python3 tools/avsync_audio_telemetry_verdict.py --self-test
echo "true rc=$?"
# expect: PASS plus100 detect rc=6 path; healthy PASS; collapsed RED; respawn 79
#         self_test OK … true rc=0
```

Embedded collapsed anchors: `audio_s=138.4 wall_s=231.1` → ratio **0.599**,
`drops=1065`.

## Parent device commands (agent does not run these)

```bash
# 0) host load concurrent with cast (REQUIRED)
python3 -c 'import json;print(json.dumps({"loadavg":open("/proc/loadavg").read().split()[:3],"src":"measured"}))' \
  | tee host_load.json

# 1) cast DIRECT-PLAY 480p trekmatch blip (not a starved transcoder session)
# 2) capture HDMI audio only if video lock is dead:
arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 60 /tmp/hdmi_a.wav
echo "arecord true rc=$?"

# 3) pull daemon media lines for the same window
ssh … 'grep "media:" LOG | tail -n 400' > daemon_media.txt

# 4) score
python3 tools/avsync_audio_telemetry_verdict.py \
  --audio /tmp/hdmi_a.wav \
  --daemon-log daemon_media.txt \
  --fixture assets/avsync/sync_trekmatch_624x480_24_blip.mp4 \
  --host-load-json host_load.json \
  --json-out /tmp/av_telem_verdict.json
echo "true rc=$?"
```

### Severity ladder (PASS is strict)

| situation | VERDICT | rc |
|-----------|---------|---:|
| supply≥ok_min **and** ledger closable (frames+presents+drops) **and** markers≠FAIL | `PASS` | **0** |
| supply collapsed, drop_frac high (parent 0.599/1065) | `PACER_DROPS` or `STARVED` | **3** or **2** |
| beep period wrong | `AUDIO_MARKER_FAIL` | **4** |
| drift climbing under starvation | `SERVO_DRIFT_CLIMB` | **5** |
| file +100 ms audio delay recovered | `DESIGNED_OFFSET_DETECT` | **6** (sensitivity OK) |
| **supply ok but markers=NO-DATA and presents/residual missing** (parent 2026-08-02 live) | `INSUFFICIENT_EVIDENCE` | **78** (never pass) |
| respawn mid-window | `SESSION_INVALID` | **79** (aligns w-instr) |
| no audio and no media lines | `NO-DATA` | **77** (never pass) |

**PASS never means “supply alone looked fine.”** Parent live miss: `supply_ratio=0.999`
with `audio_markers=NO-DATA`, `presents=null`, `residual=NO-DATA` is **rc=78**.

Markers may be NO-DATA on PASS **only** when the ledger is closed (telemetry-only
health with atomic `frameLedgerTelemetryFragment`).

### Ledger ownership (do not duplicate w-instr)

Split logs (`media: frames=… drops=…` without presents + separate
`media: fpga frame_tx … presents=`) are closed by **w-instr**
`tools/daemon_media_ledger.py` (`RC_SESSION_INVALID=79` same convention).
This tool refuses PASS when unclosable and points there.

When HDMI video lock returns, **also** run glass lipsync:

```bash
python3 tools/avsync_measure_hdmi.py --duration 45 --json-out /tmp/lipsync.json
echo "true rc=$?"
```

That is the only path that settles **glass** offset; this tool says so under
`CANNOT_SETTLE`.

## Provenance tags

Every numeric field is one of: `measured` | `caller_supplied` | `DEFAULT_ASSUMED` | `NO-DATA`.  
`ok_min=0.90` is **DEFAULT_ASSUMED**. Never promote a default to a measurement
(ERROR 17).

## Coordination

| lane | owns |
|------|------|
| **this** | lipsync instrument + supply/drops telemetry verdict; pixel-blind path |
| **w-instr** | inter-frame presentation interval / judder histogram |
| **w-cpu-1** | Recv-Q / local limiter RCA |
| **parent** | all casts, HDMI, PMS, deploy |
