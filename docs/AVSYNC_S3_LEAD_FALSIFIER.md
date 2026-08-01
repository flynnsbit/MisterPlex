# S3 falsifier — is `av_drift_ms` a setpoint readout?

## Why this exists

Parent `PRESENT_PROFILE=1` @ 480p24: **pacing wait = 16.684 ms/frame** (~40% of
41.67 ms period) at CPU/wall ≈ 0.009. Pipeline is **pacer-limited by design**.
That sleep is the servo HOLD path (`avDecide`: hold while `drift + lead < 0`).

rd-review **S3** (accepted, untested until this card runs):

> Observed drift band (−21…−40 ms, **always negative**) is pinned inside
> `AV_PRESENT_LEAD_MS` (default 40) **by construction**.

### Code (quoted, not paraphrased)

`host/libmisterplex/av_clock.hpp` — `avDecide`:

```cpp
if (driftMs + leadMs < 0)
    return AvAction::Hold;
```

Comment immediately below:

> avDecide HOLDs while drift + lead < 0, so in steady state the *observed*
> av_drift_ms sits in approximately **[-lead, drop)** BY CONSTRUCTION. That band
> is a readout of AV_PRESENT_LEAD_MS, not an independent lipsync accuracy.
> … `av_drift_role=servo_error_not_lipsync`

`arm/misterplexd/main.cpp` — conf + env:

- Conf key: **`AV_PRESENT_LEAD_MS`**
- Env override (preferred): **`MISTERPLEX_AV_PRESENT_LEAD_MS`** — wins over conf,
  prints `AV_PRESENT_LEAD_MS=env:N (conf not modified)`
- Startup always prints: `misterplexd: AV_PRESENT_LEAD_MS=…`

Default `presentLeadMs_ = 40` (`media_player.hpp`).

---

## Pre-registered predictions (publish hit/miss after run)

Hypothesis **H_S3 (circular):** steady-state `av_drift_ms` tracks setpoint
`−LEAD` and lives in approximately `[−LEAD, +DROP)` (DROP default 80).

Hypothesis **H_REAL (independent):** band stays near parent’s **−21…−40** for all
LEAD values (would **falsify S3**).

| LEAD | setpoint | **P_MEDIAN band (S3)** | **P_MIN..P_MAX envelope (S3)** | H_REAL would show |
|-----:|---------:|------------------------:|--------------------------------:|-------------------|
| **20** | −20 | **[−22, −12]** | **[−28, +5]** | still ~[−40,−21] |
| **40** | −40 | **[−42, −28]** (parent saw −38) | **[−45, −15]** | ~[−40,−21] |
| **80** | −80 | **[−82, −60]** | **[−90, −40]** | still ~[−40,−21] |

### Pairwise Δ (median_B − median_A) under H_S3

| Pair | ΔLEAD | **P_Δ median** |
|------|------:|---------------:|
| 40→20 | −20 | **[+12, +28]** ms (band moves **up** toward zero) |
| 40→80 | +40 | **[−55, −25]** ms (band moves **down**) |
| 20→80 | +60 | **[−75, −40]** ms |

### Decision rules (no soft-skip)

| Observation | Verdict |
|-------------|---------|
| All three medians fall in S3 P_MEDIAN bands **and** pairwise Δ in P_Δ | **S3_CONFIRMED** — retire `av_drift_ms` as accuracy/lipsync GT |
| All three medians stay in **[−45, −15]** regardless of LEAD | **S3_FALSIFIED** — drift is a real open-loop quantity (still not HDMI lipsync) |
| Mixed / one arm multi-`session_epoch` / banner≠env | **UNSCORED** — name the check; do not invent |

### What replaces `av_drift_ms` if S3_CONFIRMED

| Metric | Role | Source |
|--------|------|--------|
| **HDMI flash↔beep `offset_ms`** | lipsync GT | `tools/avsync_measure_hdmi.py` (MS2109 v4l2+ALSA) |
| **same-rig Δmedian / slope** | drift & transport steps | cancels grabber B |
| **`av_display_offset_ms`** | open-loop content vs audio (uses presentCount) | telemetry fragment — **not** a substitute for HDMI until validated |
| **PRESENT_PROFILE pacing_wait_ms** | pacer budget | already measured 16.68 ms @ lead≈40 |
| supply_bucket `unaccounted` | frame loss | only with **one** `session_epoch`; never lipsync |

**Never:** tight `av-lock` + `av_drift` in band as “lipsync OK”.

---

## Fixture (HDMI arm) — required if you score glass

Parent saw `mean_luma=7 flashes=0 beeps=0` → **UNSCORED glass**, not a lipsync number.

| ratingKey | Asset | Markers |
|----------:|-------|---------|
| **20** | AVSync Glass 480p24 **600s** | flash+beep, design offset **0**, period **2.0 s** |
| **21** | same **audioPlus100ms** | design **+100 ms** (instrument RED) |
| **27** / bank full-bleed | 1200s GlassAV class | period **2.0 s** if that is the scanned asset |

**Do not** use idle/OCR-only/real-BBB-without-markers for flash detection.

Host already proved the tool: AudioID Δ=99.29 ms, GlassAV Δ=100.00 ms (file path).

---

## Preferred LEAD change: **env only** (conf bytes untouched)

No conf write → `cmp` backup is still taken once for paranoia.

```bash
# On device supervisor / manual restart — parent owns this.
# Banner MUST show: AV_PRESENT_LEAD_MS=env:20|40|80
MISTERPLEX_AV_PRESENT_LEAD_MS=40   # arm L40
MISTERPLEX_AV_PRESENT_LEAD_MS=20   # arm L20
MISTERPLEX_AV_PRESENT_LEAD_MS=80   # arm L80
# Unset env to return to conf/default.
```

---

## Alternate: conf key (byte-exact backup/restore)

**Key:** `AV_PRESENT_LEAD_MS=<int>` in the conf the **live** daemon loads  
(try `/media/fat/misterplex_v2/misterplex.conf` then `/media/fat/misterplex/misterplex.conf`).

```bash
HOST=${MISTER_HOST:-192.168.1.183}
# Resolve live conf + backup
ssh root@$HOST 'set -e
for c in /media/fat/misterplex_v2/misterplex.conf /media/fat/misterplex/misterplex.conf; do
  [ -f "$c" ] || continue
  echo "CONF_LIVE=$c"
  BAK="${c}.bak_s3_$(date +%Y%m%dT%H%M%S)"
  cp -a "$c" "$BAK"
  echo "BAK=$BAK"
  md5sum "$c" "$BAK"
  break
done'
# Record BAK= path from output — restore MUST use that path.
```

Set LEAD (example 20) without destroying other keys:

```bash
ssh root@$HOST 'set -e
C=CONF_LIVE_PATH   # paste from above
# remove any existing AV_PRESENT_LEAD_MS lines then append
grep -v "^AV_PRESENT_LEAD_MS=" "$C" > "$C.tmp"
echo "AV_PRESENT_LEAD_MS=20" >> "$C.tmp"
mv "$C.tmp" "$C"
grep "^AV_PRESENT_LEAD_MS=" "$C"
'
# restart daemon (parent’s supervisor path), confirm banner:
#   AV_PRESENT_LEAD_MS=conf:20
```

Restore **byte-exact**:

```bash
ssh root@$HOST 'set -e
C=CONF_LIVE_PATH
BAK=BAK_PATH
cp -a "$BAK" "$C"
cmp -s "$BAK" "$C" && echo CONF_RESTORE_CMP_OK || { echo CONF_RESTORE_CMP_FAIL; exit 2; }
md5sum "$C" "$BAK"
'
```

---

## Cast + soak per arm (parent)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane   # or your checkout with this branch
HOST=${MISTER_HOST:-192.168.1.183}

# Cast flash+beep fixture (rk=20 preferred)
scripts/plex_browse.sh --player ${HOST}:3005 play 20
# wait playing:
scripts/plex_browse.sh --player ${HOST}:3005 status

OUT=$PWD/avsync_hdmi_out/s3_L${LEAD}_$(date +%Y%m%dT%H%M%S); mkdir -p "$OUT"
# LEAD already set via env or conf; restart done; banner checked.

bash tools/avsync_capture_session_epoch.sh | tee "$OUT/epoch.txt"
echo "epoch true rc=$?"

# Daemon slice (servo evidence) — path may be logread
ssh root@$HOST 'grep -E "av_drift_ms=|av_servo_setpoint|supply_bucket|session_epoch=|AV_PRESENT_LEAD" \
  /tmp/misterplexd.log /media/fat/misterplex*/misterplexd.log 2>/dev/null | tail -n 400' \
  >"$OUT/daemon_tail.txt" 2>/dev/null || \
ssh root@$HOST 'logread | grep -E "av_drift_ms=|supply_bucket|session_epoch=" | tail -n 400' \
  >"$OUT/daemon_tail.txt"

# Optional HDMI (only if fixture flashes — else leave UNSCORED glass)
fuser -v /dev/video0 || true
DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=15 TOL_MS=200 DECODE_SRC=caller_supplied \
  OUT="$OUT" LABEL=s3L${LEAD} bash tools/avsync_lipsync_soak.sh >"$OUT/wrap.txt" 2>&1
echo "hdmi_soak true rc=$?"

# Grep servo (never pipe the soak rc):
grep -E "av_drift_ms=" "$OUT/daemon_tail.txt" | tail -n 5
python3 - <<PY
import re,statistics,sys
from pathlib import Path
t=Path("$OUT/daemon_tail.txt").read_text(errors="replace")
v=[float(x) for x in re.findall(r"\\bav_drift_ms=(-?[0-9.]+)",t)]
print("n",len(v),"median",statistics.median(v) if v else "NO-DATA",
      "min",min(v) if v else "NO-DATA","max",max(v) if v else "NO-DATA")
PY
```

Repeat for **LEAD ∈ {20, 40, 80}**. One `session_epoch` per arm. Do not pool arms.

Score:

```bash
# After three arms, fill paths:
python3 tools/avsync_score_lead_s3.py \
  --arm 20:$OUT20/daemon_tail.txt \
  --arm 40:$OUT40/daemon_tail.txt \
  --arm 80:$OUT80/daemon_tail.txt
echo "s3_score true rc=$?"
```

Or pairwise with existing helper:

```bash
LOG_A=$OUT40/daemon_tail.txt LOG_B=$OUT20/daemon_tail.txt \
  bash tools/avsync_lead_falsifier.sh score_logs
```

---

## Link to pacing wait

At LEAD=40, HOLD while `drift < −40`. Steady lock rides near the hold line →
**pacing_wait ≈ fraction of frame** spent in HOLD (parent: 16.68 ms).  
If S3 holds, changing LEAD should change **both** `av_drift` band **and**
(optionally) mean `pacing_wait_ms` from PRESENT_PROFILE — secondary check,
not required for S3 verdict.
