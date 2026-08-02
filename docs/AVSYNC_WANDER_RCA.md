# PARENT — Wander RCA + external LEAD + 240p control

Instrument validated on hardware (Δ=+111.50 ms P3 HIT). Next: cause of WANDER.

## Pre-register (publish hit/miss)

| ID | Prediction |
|----|------------|
| W1 | Same-window: if `daemon_vfps_mean < 22` AND `residual_rms_ms > 25` → class `WANDER_WITH_THROUGHPUT_COLLAPSE` |
| W2 | If `vfps_mean ≥ 23.5` AND residual > 25 → `WANDER_WITHOUT_COLLAPSE` (pacer/phase, not supply) |
| W3 | When residual high, `av_drift_ms` median still near −LEAD (servo circular) |
| W4 | Mid-window respawn → harness rc=**79** INVALID, row not scored |
| W5 | 240p control: residual_rms lower than 480p at matched session age (or NO-DATA if no 240 fixture) |
| L1 | LEAD∈{20,40,80}: external HDMI \|Δmedian vs LEAD40\| **< 25 ms** |
| L2 | Same arms: av_drift **min ≈ −LEAD** (already device-confirmed; reconfirm) |

Throughput collapse ownership: **w-geom**. This lane only **scores** glass A/V vs covariates.

---

## PASTE A — wander scatter (repeat N≥6, mix session ages)

Device already on **DECODE=624x480**, fixture **rk=20** (or 21). `/dev/video0` free.

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
HOST=${MISTER_HOST:-192.168.1.183}
fuser -v /dev/video0 || true
arecord -l | head -6

# Cast once; do NOT recast between rows unless session dies
scripts/plex_browse.sh --player ${HOST}:3005 play 20
sleep 8
scripts/plex_browse.sh --player ${HOST}:3005 status

ROOT_OUT=$PWD/avsync_hdmi_out/wander_$(date +%Y%m%dT%H%M%S)
mkdir -p "$ROOT_OUT"

for i in 1 2 3 4 5 6; do
  OUT="$ROOT_OUT/r$i"
  mkdir -p "$OUT"
  # optional: sleep to sample different session ages (0, 60, 120, ...)
  # sleep $(( (i-1)*30 ))
  TIER=480p DECODE_GEOM=624x480 LABEL=r$i OUT="$OUT" \
    DURATION=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=15 \
    bash tools/avsync_wander_rca.sh >"$OUT/wrap.txt" 2>&1
  echo "wander_r$i true rc=$?"
  grep -E '^(VERDICT=|rca_class=|residual_rms|daemon_vfps|daemon_drops|session_epoch|INVALID)' \
    "$OUT/wrap.txt" "$OUT/r${i}_rca.json" 2>/dev/null | head -40
  # If rc=79: session respawn — recast 20, continue; do NOT keep row as data
done

# Scatter (appended per row under each OUT — also copy):
find "$ROOT_OUT" -name wander_rca_scatter.csv -exec cat {} \;
```

**Same-window rule:** daemon scrape runs concurrent with HDMI soak; epoch before==after required.

**Do not** pool rows across different `session_epoch`. **Do not** treat rc=79 as wander evidence.

### How to read
- Cloud of points with low vfps + high residual → collapse-driven (hand score to w-geom).
- High residual at vfps≈24 → not supply; phase/pacer/path (stay in this lane).
- av_drift stuck near −40 while residual 100+ → S3 still true under load.

---

## PASTE B — external LEAD falsifier (3 arms)

Conf is user-owned — backup + **cmp** restore byte-exact.

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
HOST=${MISTER_HOST:-192.168.1.183}
# Resolve LIVE conf root (v2 if live) — same two-roots rule
ssh root@$HOST 'for d in /proc/[0-9]*; do e=$(readlink -f $d/exe 2>/dev/null)||continue; case $e in */misterplexd) root=${e%/bin/misterplexd}; echo ROOT=$root; ls -la $root/misterplex.conf 2>/dev/null; break;; esac; done'

# On device (parent):
#   CONF=$ROOT/misterplex.conf
#   cp -a "$CONF" "${CONF}.bak_lead_ext_$(date +%Y%m%d%H%M%S)"
#   For each LEAD in 20 40 80:
#     set AV_PRESENT_LEAD_MS=$LEAD in conf OR env MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD
#     restart daemon; verify banner LEAD
#     cast rk=20; wait session; run:

for LEAD in 20 40 80; do
  echo "=== PARENT: set LEAD=$LEAD, restart, verify banner, cast rk=20 ==="
  OUT=$PWD/avsync_hdmi_out/lead_ext_${LEAD}_$(date +%Y%m%dT%H%M%S)
  mkdir -p "$OUT"
  bash tools/avsync_capture_session_epoch.sh | tee "$OUT/epoch.txt"; echo "epoch true rc=$?"
  TIER=480p LABEL=lead$LEAD OUT="$OUT" DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 \
    bash tools/avsync_wander_rca.sh >"$OUT/wrap.txt" 2>&1
  echo "lead_ext_$LEAD true rc=$?"
  # scrape av_drift min from daemon window:
  grep -oE 'av_drift_ms=-?[0-9.]+' "$OUT/lead${LEAD}_daemon_window.txt" | sort -t= -k2 -n | head -3
  grep -E 'median_offset_ms_raw=|residual_rms|rca_class=|daemon_av_drift' \
    "$OUT/wrap.txt" "$OUT/lead${LEAD}_rca.json" 2>/dev/null
done
# restore conf; cmp against bak
```

**Pre-reg L1:** HDMI medians across LEAD stay within **25 ms** of each other (B cancels in Δ).  
**Pre-reg L2:** av_drift min ≈ −20 / −40 / −80.

---

## PASTE C — 240p control

Need a **flash+beep** asset at 240p (e.g. AudioID/Glass 426×240 or library rk if present). If none: stop with NO-DATA — do not use plain BBB.

```bash
# Parent: identify 240p blip rk (status/library). Example placeholder RK240=
RK240=REPLACE_ME
scripts/plex_browse.sh --player ${HOST}:3005 play "$RK240"
sleep 8
OUT=$PWD/avsync_hdmi_out/ctrl240_$(date +%Y%m%dT%H%M%S)
TIER=240p DECODE_GEOM=426x240 LABEL=c240 OUT="$OUT" \
  DURATION=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=15 \
  bash tools/avsync_wander_rca.sh >"$OUT/wrap.txt" 2>&1
echo "ctrl240 true rc=$?"
```

Compare `residual_rms_ms` / `rca_class` to 480p rows at similar session age.

---

## Host re-check (no device)
```bash
bash tests/unit/test_avsync_live_log_resolve.sh; echo "live_log true rc=$?"
bash tests/unit/test_avsync_measure_hdmi.sh; echo "unit true rc=$?"
```

## Session survival
Daemon self-exits rc=0 irregularly. **epoch_before != epoch_after → rc=79 INVALID.**  
Never fold INVALID into wander scatter means.
