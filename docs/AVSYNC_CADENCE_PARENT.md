# PARENT — glass cadence + N≥6 + 240p (post pair_run2/3)

## Pre-reg scored (yours → mine)

| ID | Result |
|----|--------|
| W1 underproduce | **MISS** (parent) — vfps flat 23.9, drops_delta=0 on WANDER |
| W2 residual>25 | **threshold too coarse** — real effect residual 14.4 vs tol 12.44 |
| W2′ | `WANDER ∧ vfps≥23.5 ∧ drops_delta=0` → **HIT** (presentation-side) |

## SNR honesty (pair_run2 vs pair_run3) — measured from your logs

| | STABLE | WANDER |
|--|------:|-------:|
| residual_rms | 10.857 | 14.398 |
| excess_wander | 5.208 | 10.796 |
| det_max | 22.70 | **50.80** |
| residual/quant | 1.14 | 1.51 |
| vs tol 12.440 | under | over by 1.96 ms |

- Quant floor T/√12 = **9.53 ms**. Both windows sit near it.
- **Binary gate differs** by construction; **RMS separation is only 3.54 ms** — low SNR.
- **det_max 22.7 vs 50.8** is the stronger contrast.
- **F-test on pair logs = NO-DATA** (series not in log). Need `*_offset_timeseries.csv`.
- **Rate / “intermittent” from n=2 = UNJUSTIFIED.** Run N≥6.

Host F-test on earlier live mild vs heavy (residual 13.5 vs 35.8): **F≈7.08 > Fcrit≈1.95 → distinguishable** (approx). That pair is high-SNR; pair_run2/3 may not be.

## Scope (binding)

| Channel | Tool | Can answer user? |
|---------|------|------------------|
| Lipsync phase | `avsync_measure_hdmi` residual | audio/lips — **yes** |
| Marker cadence | inter_flash p50/p95/p99/max | multi-period gaps — **partial** |
| Frame drops | `glass_template_skip` + counter | “frames dropped” — **not lipsync tool** |
| Motion judder | content cadence / separate | “didn’t look 480p” — **not lipsync tool** |

**Do not stretch residual_rms to mean drops.** Parent already: WANDER @ vfps 23.9 drops_delta=0.

## PASTE 1 — N≥6 multiwindow (480p, rk=20 playing)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
HOST=${MISTER_HOST:-192.168.1.183}
fuser -v /dev/video0 || true
scripts/plex_browse.sh --player ${HOST}:3005 play 20
sleep 8
OUT=$PWD/avsync_hdmi_out/mw6_$(date +%Y%m%dT%H%M%S)
N=6 DURATION=45 GAP_S=20 MARKER_PERIOD_S=2.0 MIN_PAIRS=15 MIN_SCORED=6 \
  TIER=480p DECODE_GEOM=624x480 OUT="$OUT" \
  bash tools/avsync_multiwindow.sh >"$OUT/wrap.txt" 2>&1
echo "multiwindow true rc=$?"
column -t -s, "$OUT/multiwindow_summary.csv" 2>/dev/null || cat "$OUT/multiwindow_summary.csv"
# Look at: timing_class counts, n_interval_outliers, pool_f_test.txt
```

rc=79 row = respawn INVALID — recast, do not score.

## PASTE 2 — cadence-only on an existing capture dir

```bash
python3 tools/avsync_glass_cadence.py \
  --timeseries PATH/rk20_offset_timeseries.csv \
  --compare-timeseries PATH2/other_offset_timeseries.csv \
  --marker-period-s 2.0 --label A --label-b B
echo "cadence true rc=$?"
```

## PASTE 3 — 240p control (same multiwindow)

```bash
# RK240 = flash+beep 240p library key (NO-DATA if none — do not use plain BBB)
RK240=REPLACE
scripts/plex_browse.sh --player ${HOST}:3005 play "$RK240"
OUT=$PWD/avsync_hdmi_out/mw6_240_$(date +%Y%m%dT%H%M%S)
N=6 DURATION=45 TIER=240p DECODE_GEOM=426x240 OUT="$OUT" \
  bash tools/avsync_multiwindow.sh; echo "mw240 true rc=$?"
```

## Frame-drop complaint (separate instrument — do not use soak)

```text
python3 tools/glass_template_skip.py CAP_DIR --templates T.pkl --pts pts.csv \
  --source-fps 24 --capture-fps <measured> --refresh-hz 60
```

w-lint owns pair script two-roots `DAEMON_LOG_REMOTE`; do not duplicate.
