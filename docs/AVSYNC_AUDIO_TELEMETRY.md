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
| LIVE RK6 (void transport) | 0.999 | −24 | 4 | 272 kbit/s; markers NO-DATA → **rc=78** |

- **`av_drift_ms` climbs as supply falls** while the old `clock=av-lock` string was
  meaningless (hardcoded; removed). Drift is still **servo error**, not lipsync GT
  (`av_clock.hpp` / `AV_PRESENT_LEAD_MS` pin). Bounded closed-loop error is not lipsync.
- **PMS Docker on the agent host** contaminates **transcode** runs
  (`complete=0 speed=0` vs healthy `complete=1 speed=19.8`). Prefer **direct-play**
  fixtures; always publish concurrent **host load**.
- HDMI grabber may be **pixel-blind** (`Pixelclock: 0 Hz`). Instrument must verdict
  from **audio + daemon telemetry**; pixels are confirmation when lock returns.
- **Intermittent ~25%** degradation: same asset consecutive runs supply 0.837 then
  0.997. **Single-run A/B has no power** (fleet-wide). Within-run only for supply.
- **rk6 272 kbit/s** sits below worst observed 1 s delivery window (~45.7 KB/s) —
  **void endpoint** for local-vs-path / transport claims (PASS was guaranteed).

## Tool

`tools/avsync_audio_telemetry_verdict.py`

### Required axes (coverage printed every run)

| axis | names | NO-DATA means |
|------|-------|---------------|
| `audio_markers` | `av_sync_verdict` | **A/V name is INSUFFICIENT** regardless of supply |
| `supply_ratio` | `supply_verdict` | throughput unknown |
| `ledger` | `ledger_verdict` | residual unclosable |
| `av_drift_servo` | `servo_verdict` | servo samples missing |

**Rule (rd-review, parent-agreed):** ANY required axis NO-DATA implies overall
`INSUFFICIENT_EVIDENCE` **rc=78**. Never PASS on supply alone. One axis never
carries a verdict named for another.

### `supply_ratio` is VOID for local-vs-path

Parent measured: `audio_s * 24` approx equals `frames` within **0.15%** lockstep.
ffmpeg produces A+V from one process — video pipe back-pressure stalls audio
production with the socket. **Socket-starved and video-consumer-blocked predict
the same 0.837.**

Tag always printed: `discriminator_role=VOID_ENDPOINT_local_vs_path`.
Local vs path ownership: **w-instr** `recv_q` + ffmpeg `wchan` (do not duplicate).

### What it settles

1. **supply_ratio** throughput starvation only (not path vs consumer)
2. **drops vs publish_misses vs residual** with code semantics (below)
3. **Audio marker cadence** (1 kHz beep every `marker_period_s`) when captured
4. Whether **av_drift_ms is climbing** during collapse (servo fact, not lipsync)
5. **Content fps** from ffprobe (`measured`) / PMS `frameRate` (`caller_supplied`)

### What it cannot settle (printed every run)

- Glass lipsync without flash+beep **video** capture
- Visible judder / inter-frame histogram (**w-instr**)
- Path capacity vs local limiter via `supply_ratio` (**VOID** — w-instr recv_q/wchan)
- Device defect from transcoder-starved cast (host-load confound)
- Using `av_drift_ms` as lipsync accuracy (run LEAD 40→20→40 falsifier)
- Single-run A/B of intermittent supply collapse

## drops=1065 — code meaning (not a vibe)

| counter | increments | reset (this tree) | means |
|---------|------------|-------------------|-------|
| **`drops` / `droppedFrames_`** | `media_player.cpp` ~**:4183–4185** `if (!present) droppedFrames_.fetch_add(1)` after `avDecide` → **Drop** | play-path ~**:3010** `store(0)` | **Deliberate A/V-pacer skip** of `presentCleanFrame` |
| **`publish_misses` / `publishMisses_`** | ~**:3641** DDR/FPGA publish fail inside `presentCleanFrame` | play-path ~**:3011** | Present attempted; arm publish failed |
| **`residual`** | arithmetic | — | **`frames − presents − drops`** (`frame_ledger.hpp`) |

So **drops=1065** means the pacer chose Drop 1065 times. It does **not** mean
ffmpeg failed to produce 1065 frames. If `residual==0` and `publish_misses==0`,
every non-present was a pacer Drop.

## Fixture (direct-play 480p blip)

```bash
python3 scripts/gen_avsync_blip.py --only trekmatch480 --duration 120
# → assets/avsync/sync_trekmatch_624x480_24_blip.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate \
  -of csv=p=0 assets/avsync/sync_trekmatch_624x480_24_blip.mp4
# expect: 624,480,24/1   fps_src=measured
```

Bitrate **1200k** so lab path can direct-play. Do not score through `complete=0`.

Host RBG on shipped +100 ms twin:

```bash
python3 tools/avsync_audio_telemetry_verdict.py \
  --audio assets/avsync/sync_glass_av_480p24_600s_audioPlus100ms.mp4 \
  --designed-offset-ms 100 --marker-period-s 2.0
echo "true rc=$?"   # DESIGNED_OFFSET_DETECT rc=6

python3 tools/avsync_audio_telemetry_verdict.py \
  --audio assets/avsync/sync_glass_av_480p24_600s.mp4 \
  --designed-offset-ms 0 --marker-period-s 2.0
echo "true rc=$?"   # markers-only without daemon → rc=78 INSUFFICIENT
```

## Red-before-green (host, no device)

```bash
cd /path/to/worktree
python3 tools/avsync_audio_telemetry_verdict.py --self-test
echo "true rc=$?"
# expect true rc=0
# plus100 rc=6; full-axis PASS rc=0; collapsed PACER_DROPS rc=3;
# parent-tonight / telemetry-only markers missing → INSUFFICIENT rc=78;
# supply VOID_ENDPOINT tag; respawn rc=79
```

## Parent device commands (agent does not run these)

```bash
# 0) host load concurrent with cast (REQUIRED)
python3 -c 'import json;print(json.dumps({"loadavg":open("/proc/loadavg").read().split()[:3],"src":"measured"}))' \
  | tee host_load.json

# 1) cast DIRECT-PLAY 480p trekmatch blip (not starved transcoder / not rk6-void)
# 2) capture HDMI audio (video lock optional):
arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 60 /tmp/hdmi_a.wav
echo "arecord true rc=$?"

# 3) daemon media lines — prefer atomic frames+presents+drops on one line
#    (frameLedgerTelemetryFragment). Split stats/DDR → w-instr ledger first.
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
| **all 4 axes DATA** and each ok | `PASS` | **0** |
| coverage complete + supply collapsed / high drop_frac | `STARVED` / `PACER_DROPS` | **2** / **3** |
| coverage complete + beep period wrong | `AUDIO_MARKER_FAIL` | **4** |
| coverage complete + drift climbing under starvation | `SERVO_DRIFT_CLIMB` | **5** |
| file +100 ms audio delay recovered | `DESIGNED_OFFSET_DETECT` | **6** (sensitivity only) |
| **ANY axis NO-DATA** (markers missing, ledger open, …) | `INSUFFICIENT_EVIDENCE` | **78** (never pass) |
| respawn mid-window | `SESSION_INVALID` | **79** (= w-instr) |
| zero axes have data | `NO-DATA` | **77** (never pass) |

**Illegitimate (fixed):** `reason=supply_ok_markers_ok` with `audio_markers=NO-DATA`.
That is now **rc=78**. Coverage block lists `nodata_axes` every run.

### Ledger ownership (do not duplicate w-instr)

Split logs (`media: frames=… drops=…` without presents + separate
`media: fpga frame_tx … presents=`) → **w-instr** `tools/daemon_media_ledger.py`
(`RC_SESSION_INVALID=79`). This tool skips `fpga frame_tx` lines and refuses PASS
when residual unclosable.

## LEAD 40→20→40 falsifier (no grabber, no conf edit)

See **`docs/AVSYNC_S3_PARENT_RUN.md`**. Env only:
`MISTERPLEX_AV_PRESENT_LEAD_MS` via supervise inherit (`main.cpp:626-633`, banner
`AV_PRESENT_LEAD_MS=env:N` at ~`:668`). Prove banner; pre-reg Δ about ±20 ms.

## Provenance tags

Every numeric field: `measured` | `caller_supplied` | `DEFAULT_ASSUMED` | `NO-DATA`.  
`ok_min=0.90` is **DEFAULT_ASSUMED**. Never promote a default (ERROR 17).

## Coordination

| lane | owns |
|------|------|
| **this** | multi-axis audio+telemetry verdict; LEAD falsifier procedure; supply VOID tag |
| **w-instr** | split ledger reconstructor; recv_q/wchan local-vs-path; judder histogram |
| **w-cpu-1** | root-cause of path limiter (not telemetry) |
| **w-asset480** | CBR ladder / direct-play assets |
| **parent** | all casts, HDMI, PMS, deploy, LEAD arms |
