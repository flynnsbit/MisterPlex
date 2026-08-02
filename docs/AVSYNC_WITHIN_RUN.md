# Within-run framerate + A/V-relation instrument

**Tool:** `tools/avsync_within_run.py`  
**Branch tip:** `w-avsync-lane`  
**User bug (open):** *verify framerate and audio sync on the 480p path; frames look dropped.*

Agent does **not** touch the device. Parent runs all casts/captures.

---

## Established facts this tool respects

| Fact | Consequence for design |
|------|------------------------|
| `recv_q>0` 100% of 1 Hz samples on instrumented 300 s run | Not an empty-socket transport story |
| ~25% intermittent | **No single-run A/B** |
| `audio_s×24 ≈ frames` (0.15%) when degraded | Common ffmpeg stall; `supply_ratio` VOID for local-vs-path |
| drops = pacer only; 356/984 short ≈ 7.1% | **never_arrived** dominates; do not read drops as “the loss” |
| bitrate request changes geometry (397→312×240 vs 2000→624×480) | Flag mid-run `decode=` shift (rc=5) |
| w-instr locus480 v1: `recv_q_gt0=1.0` + `pipe_write=1.0` on **healthy** | Saturation guard mandatory |

---

## Two questions → two axes

### (A) FPS_SUSTAINED — is 24 fps held wall-second by wall-second?

- Build 1 s intervals from consecutive `media:` lines:  
  `iv_vfps = Δframes / Δwall_s` (and `iv_pfps` if presents present).
- Optional: prefer `present_window d_frames` when `PRESENT_PROFILE=1`  
  (**consume** w-cpu lines; **do not** re-implement H-READ/H-DDR/H-PACER).
- Report p10/p50/p90, fraction of windows ≥ `content_fps * ok_frac`  
  (`ok_frac=0.95` **DEFAULT_ASSUMED**).
- Session deficit:  
  `expected = content_fps * wall_s`  
  `short = expected - frames`  
  `never_arrived = short - drops`  
  with drops meaning quoted: `droppedFrames_.fetch_add` after Drop  
  (`media_player.cpp` ~**:4185** this tree).

**Saturation note:** `iv_vfps ≈ content_fps` on healthy windows is **expected**
headroom-**down**. Unlike `recv_q_gt0_frac=1.0`, this axis can fall in a
collapse. Not a ceiling trap.

### (B) AV_RELATION — is the daemon A/V relationship locked or unlocking?

#### `av_drift_ms` honesty (your suspicion is largely correct)

Quoted product path:

```text
clockMs = audibleClockMs(audioBytes_, audioQueuedBytes_)   # mraudio_status.hpp
frameMs = frameContentMs(frameIndex, …)                    # av_clock.hpp
drift   = clockMs - frameMs
avDecide: Hold while drift + lead < 0
```

When the Hold loop can keep up, published `av_drift_ms` sits in approximately
**[-lead, drop) BY CONSTRUCTION**. Absolute drift is then a **setpoint/deadband
readout**, not lipsync accuracy, and not proof the user hears sync.

**Not completely inert:** when video production lags and Hold cannot catch up,
drift **climbs** (parent saw −22 → +56 → +81). That climb is a within-run
**unlock** signal vs the healthy baseline of the **same** soak — still **not**
glass lipsync.

`av_display_offset_ms` (presentCount-based) does **not** free-heal on Drop the
way chasing `frameIndex` does — preferred when present on the line.

**Saturation guard:** if healthy-portion drift has low pstdev and median inside
the Hold deadband → `SATURATED_PINNED_DEADBAND`. Absolute drift must not be
sold as “sync OK”.

**Glass GT** remains `tools/avsync_measure_hdmi.py` flash↔beep when grabber lives.

---

## PRE-REGISTRATION (publish hit/miss after your run)

| ID | Prediction |
|----|------------|
| **H_FPS_OK** | ≥95% of 1 s intervals have `iv_vfps ≥ 0.95×content_fps`; p10 near content rate. Anchor: healthy `vfps=23.9 pfps=23.8 drops=14`. |
| **H_FPS_COLLAPSE** | Cluster of intervals ~20 fps not 24; `never_arrived >> drops`. Anchor: `vfps=20 pfps=18.6 drops=356 frames=5011 wall=249.8` short≈984. |
| **H_SERVO_PINNED_HEALTHY** | Healthy drift median in deadband, pstdev≤6 → `SATURATED_PINNED_DEADBAND`; verdict name contains `NOT_LIPSYNC`. |
| **H_SERVO_UNLOCK_ON_COLLAPSE** | If collapse is video-behind-audio: degraded−healthy drift median ≥ **+25 ms** → `SERVO_UNLOCK_CLIMB`. |
| **H_LOCKSTEP_PINNED** | If collapse is common upstream stall: FPS_COLLAPSE **and** `SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE` (drift stays near deadband while both lag wall). **Hit for lockstep, not a miss of unlock.** |
| **H_PRESENT_WINDOW** | With `PRESENT_PROFILE=1`, degraded seconds majority H-READ or H-DDR not H-PACER-only (w-cpu owns class meaning). |
| **MISS_RULE** | FPS_OK while `short>>drops` without startup-only story; or lipsync PASS from av_drift alone; or climb claimed with climb_ms=NO-DATA. |

---

## PRESENT_PROFILE (w-cpu `6960d5b2`) — why not duplicated

`present_window.hpp` already classifies H-READ/H-DDR/H-PACER/H-HOLD per second
and is the right **stall-locus** instrument. This tool:

- **Builds on it** when lines exist (`--prefer-present-window`).
- **Does not** re-implement the classifier or compete on H-* names.
- Works on **ea643e99** without profile via reconstructed `Δframes/Δwall`.

Deploy profile only when you want locus split; FPS/sync axes do not require it.

---

## Host red-before-green (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane

python3 tools/avsync_within_run.py --self-test
echo "true rc=$?"
# expect true rc=0
# healthy → rc=0 FPS_OK_SERVO_PINNED_NOT_LIPSYNC
# lockstep collapse → rc=2 FPS_COLLAPSE + SERVO_STILL_PINNED_UNDER_FPS_COLLAPSE
# unlock climb → rc=4 BOTH (or 2|3)
# geom shift → rc=5; respawn → rc=79; empty → rc=77
```

---

## Parent device procedure (you run)

### 1) Long soak on a **fixed geometry** 624×480 direct-play asset

≥4–5 minutes so ~25% class can appear **inside one session**.  
Do **not** change maxVideoBitrate mid-soak (geometry confound).

Optional locus (off after capture — daily driver):

```text
PRESENT_PROFILE=1   # conf or env if supported on tip that has 6960d5b2
```

Default product path: leave profile **off**; media lines alone are enough for
FPS + servo axes.

### 2) Pull log for one continuous session_epoch

```bash
# on capture host after soak
grep -E 'media: (frames=|present_window)' DAEMON_LOG | tee within_run_media.txt
echo "pull true rc=$?"

# score
python3 tools/avsync_within_run.py \
  --daemon-log within_run_media.txt \
  --content-fps 24 --content-fps-src caller_supplied \
  --json-out within_run_verdict.json
echo "true rc=$?"
```

Prefer `--content-fps` from PMS/ffprobe **measured** when available; tag src.

### 3) How to read rc

| rc | VERDICT | Meaning |
|---:|---------|---------|
| 0 | `FPS_OK_*_NOT_LIPSYNC` | Within-run rate held; servo deadband pinned or stable — **not** glass sync PASS |
| 2 | `FPS_COLLAPSE` | Production short within-run (user framerate complaint) |
| 3 | `SERVO_UNLOCK_CLIMB` | Drift/display_offset climbed vs healthy baseline |
| 4 | `BOTH_FPS_AND_SERVO_BAD` | Both axes bad |
| 5 | `GEOMETRY_SHIFT` | `decode=` changed mid-run — void FPS compare |
| 78 | `INSUFFICIENT_EVIDENCE` | Thin/marginal |
| 79 | `SESSION_INVALID` | epoch/pid/counter reset mid-window |
| 77 | `NO-DATA` | no intervals |

If soak is event-free: rc=0 with `SERVO_PINNED_DEADBAND_NO_EVENT` is **expected**
and does **not** prove the 25% class is gone — only that this soak had no event.

### 4) Optional glass lipsync (grabber lock required)

```bash
python3 tools/avsync_measure_hdmi.py --duration 60 --json-out lipsync.json
echo "true rc=$?"
```

Only path that settles **perceived** A/V offset.

### 5) Optional PRESENT_PROFILE histogram (w-cpu recipe)

```bash
awk '/present_window/ {
  for(i=1;i<=NF;i++) if($i ~ /^class=/){c=$i;sub("class=","",c);h[c]++}
} END {for (k in h) print h[k], k}' within_run_media.txt | sort -nr
```

Paste histogram + `within_run_verdict.json` reasons back to the lane.

---

## Explicit non-claims

- Does not fix 480p drops.
- Does not use `supply_ratio` as pass/fail or local-vs-path.
- Does not claim lipsync from `av_drift_ms`.
- Does not replace w-cpu present_window locus or w-instr locus480 magnitude.
- Does not authorize bitrate-ladder A/B without per-arm `decode=` geometry.
