# 480p glass frame loss — decision-complete attribution (A1–A5)

**Finding (parent, pixel-confirmed):** 4 / 568 = **0.70%** steady-state source
frames absent on HDMI (480p, burned-in counter, **frameRate=24.000** — not 23.976).
Daemon `drops` can stay flat. Telemetry cannot see this class until residual +
supply_gap + glass are combined.

**This agent does not touch the device.** Parent deploys, captures, scores.

---

## D1 — Discriminator for residual=0 + glass holes

### What residual alone cannot do

```
unaccounted = frames - presents - drops     # integer, resolution = 1 frame
```

| Residual cell | Blind to |
|---------------|----------|
| `unaccounted = 0` | (a) frames **never produced** (never enter `frames`) |
| | (c) **post-present** scanout (present already counted) |

So the old row "unaccounted≈0 ⇒ supply **or** scanout" is **one cell, two ends
of the pipe**. It is the most likely outcome and must be split.

### Discriminator available **now** (no new device binary fields)

On **one** `session_epoch`, steady window `wall_s ∈ [T0, T1]` (default T0=10):

| Symbol | Definition | Source |
|--------|------------|--------|
| `d_wall_s` | wall_s(T1)−wall_s(T0) | measured 1 Hz lines |
| `d_frames` | frames(T1)−frames(T0) | measured |
| `expected` | `d_wall_s * fps_num / fps_den` | derived (fps **caller_supplied** 24/1) |
| **`supply_gap`** | `expected − d_frames` | derived |
| **`host_gap`** | unaccounted(T1)−unaccounted(T0) | measured delta |
| **`glass_holes`** | ABSENT source indices in same window | caller_supplied (glass ledger) |

**Meaning of supply_gap (not a guess):** with product CFR `fps=num/den` forced on
the ffmpeg chain, wall×fps is the schedule the pipe is built to match. If the
daemon assembled fewer frames than that schedule, the shortfall is
**pre-`frameIndex` (PMS/ffmpeg/pipe supply)**. If supply matched and host residual
stayed flat while glass still has holes, presents were counted but pixels did not
show the new source index ⇒ **post-present (DDR/RTL/scanout)**.

### What is **not** available today

| Candidate | Status |
|-----------|--------|
| ffmpeg `frame=` count vs `frameIndex` | **NOT in logs.** Play path uses `-nostats`; stderr pump **discards** `frame=` / `fps=` lines (`media_player.cpp` stderr loop). Claiming equality would violate Rule 0. |
| PMS delivered frame count | **NOT** in daemon telemetry. |
| Monotonic source index to publish | burned-in on fixture only; daemon does not OCR. |

**Minimum addition** if wall×fps is rejected as too soft: emit
`ffmpeg_out_frames=` by parsing the last `frame=N` (drop `-nostats` or add
`-progress pipe:3`) and stop discarding those lines. Then
`ffmpeg_gap = ffmpeg_out_frames − frames` splits demux/decode vs daemon read.

### Exact thresholds (must resolve ~15 holes in ~2160)

Parent scale: ≥90 s soak, skip 10 s → ≥80 s steady @ 24.000 ⇒ **expected ≥ 1920**
frames; **0.70% ≈ 13.4 → ~15 holes**.

Counters are **integers** ⇒ resolution **1 frame**.

| Name | Value | Role |
|------|------:|------|
| `HOST_GAP_FLAT` | **2** | host_gap ≤2 **cannot** explain 15 glass holes |
| `HOST_GAP_HIT` | **10** | host_gap ≥10 **can** carry the ~15-hole signal |
| `SUPPLY_GAP_FLAT` | **2** | same for supply_gap |
| `SUPPLY_GAP_HIT` | **10** | same |
| `PAIR_TOL` | **5** | \|gap − glass_holes\| for "explains glass" |
| `GLASS_LOSS_MIN` | **3** | below → do not attribute (OCR/noise) |
| `MIN_STEADY_S` | **60** | window length floor |

**Resolution proof:** FLAT≤2 and HIT≥10 leave **(3..9) = AMBIGUOUS** — never
collapsed into 0 or 15. Self-test in `tools/analyze_glass480_stage.py`:
`15∈HIT`, `0∈FLAT`, mid-band → `rc=2`. A threshold of "≈0" that used e.g. 5% of
total (108 frames) would be **blind** to 15; we use **absolute frame counts**, not
fractions of 2160.

### Decision table (tool-encoded)

| glass_holes | PIPE_* | host_gap | supply_gap | STAGE |
|------------:|:------:|---------:|-----------:|-------|
| ≥3 | yes | * | * | **PIPE** (stop) |
| ≥3 | | ≥10 & ≈glass | * | **HOST_MID** (± publish if pm≈host) |
| ≥3 | | ≤2 | ≥10 & ≈glass | **PRE_FRAMEINDEX_SUPPLY** |
| ≥3 | | ≤2 | ≤2 | **POST_PRESENT_SCANOUT** |
| ≥3 | | else | else | **AMBIGUOUS** rc=2 |
| <3 | | | | **NO-DATA** rc=77 |

```bash
python3 tools/analyze_glass480_stage.py --self-test; echo "true rc=$?"
python3 tools/analyze_glass480_stage.py \
  --log /path/daemon.log --glass-holes N \
  --fps-num 24 --fps-den 1 --t0-s 10
echo "true rc=$?"
```

---

## D2 — A5 falsifier (setpoint tracking, **not** lipsync)

**Claim under test:** `av_drift_ms` tracks `AV_PRESENT_LEAD_MS` (servo error).
**PASS does not prove lipsync.** Grabber (`avsync_measure_hdmi.py`) remains GT.

### Prefer env — do not edit user conf

```text
MISTERPLEX_AV_PRESENT_LEAD_MS=<int>   # overrides conf; conf file not written
```

Startup must show `AV_PRESENT_LEAD_MS=env:20` (or `env:40`) and an override banner
`(conf not modified)`.

```bash
CONF=/media/fat/misterplex/misterplex.conf
cp -a "$CONF" "/media/fat/misterplex/misterplex.conf.bak_lead_$(date +%Y%m%d%H%M%S)"
# restore only if something wrote conf:
# cp -a "$BACKUP" "$CONF" && cmp -s "$BACKUP" "$CONF" && echo RESTORE_OK
```

Keep `DECODE=624x480`, `PRESENT=fpga`, `IDLE_SCREEN=logo` unchanged.

### Sequence + PASS/FAIL

```bash
MISTERPLEX_AV_PRESENT_LEAD_MS=40 ./misterplexd ...   # arm A, ≥70 s wall
MISTERPLEX_AV_PRESENT_LEAD_MS=20 ./misterplexd ...   # arm B, conf bytes identical
```

| Check | PASS | FAIL |
|-------|------|------|
| setpoint A/B | **−40** / **−20** | else |
| median av_drift B−A | **∈ [+12, +28] ms** | outside |
| conf cmp to backup | **identical** | any diff |
| lipsync from this test | **forbidden** | claiming lipsync OK |

`av_display_offset_ms`: record; not required to equal `−lead`.

---

## D3 — Soak pre-register (≥90 s, T0=10 s, one session_epoch)

### Instrument health

| Field | PASS (steady) | FAIL |
|-------|---------------|------|
| session_epoch | **one** value | change mid-window |
| PIPE_* | **absent** | any → PIPE stage |
| delivery_verified | **1** | stays 0 |
| Δdrops (wall≥10) | **≤2** | ≥10 unexplained |
| Δpublish_misses | **0** clean prior | ≥10 → HOST_MID_PUBLISH |
| host_gap | **≤2** clean prior | ≥10 → HOST_MID |
| av_servo_setpoint_ms | **−lead** | mismatch |
| av_servo_margin_ms | **∈ [0, 80]** | sustained <0 |
| av_display_offset_ms | record only | not lipsync PASS |
| av_drift_ms | near −lead | servo health only |

### Stage falsifiers

- Claimed **supply**, got POST_PRESENT with supply_gap≤2, host_gap≤2, glass≥10 → **FALSIFIED**
- Claimed **scanout**, got PRE_FRAMEINDEX with supply_gap≥10 ≈ glass → **FALSIFIED**
- Claimed **DDR publish**, publish_misses_delta≤2 while glass≥10 → **FALSIFIED**
- glass≥10 and AMBIGUOUS → **incomplete**, not a pass

```bash
python3 tools/analyze_glass480_stage.py --self-test; echo "true rc=$?"
python3 tools/frame_ledger_report.py --log DAEMON.log --ledger LEDGER; echo "true rc=$?"
python3 tools/glass_frame_ledger.py --png-dir PNG --pts-csv PTS \
  --src-fps 24/1 --src-fps-src caller_supplied; echo "true rc=$?"
python3 tools/analyze_glass480_stage.py --log DAEMON.log --glass-holes N \
  --fps-num 24 --fps-den 1 --t0-s 10; echo "true rc=$?"
```

## Reference

A1–A4 in tree; A5 servo metrics + `MISTERPLEX_AV_PRESENT_LEAD_MS`; guard `63b98803`.
fps **24.000** only for this RCA.
