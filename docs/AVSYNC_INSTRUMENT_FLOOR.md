# PARENT — Instrument floor control (blocks all device A/V claims)

## Position (parent ERROR 21 — accepted)

> Two 60 s windows @ 624×480: residual 10.9 and 14.4 ms vs tol 12.4 ms are
> **statistically indistinguishable (p≈0.14)**. No device-side lipsync defect
> established. WANDER/STABLE flip framing **retracted**.

- `drops_delta` is **pacer Drop only** — not presentation.
- `detrended_max` is fragile (n=1 tail) — scorer now headlines **`detrended_p95_abs_ms`**.
- W2 “residual>25 too coarse” **withdrawn** — 14.4 is near floor.

## Beat model (measured T_cap from live reports)

| quantity | value | src |
|----------|------:|-----|
| capture_period_ms | **33.0** | measured live report median dt |
| marker_period_s | **2.0** | caller_supplied rk=20 |
| phase_step_ms | **20.0** | derived 2000 mod 33 |
| markers_per_beat | **33** | derived gcd |
| **beat_period_s** | **66.0** | derived |
| quant_rms T/√12 | **9.526** | derived |

**A 60 s window is shorter than one 66 s beat.** Adjacent windows can sit on
different arcs of the sampling-phase beat and flip STABLE↔WANDER **without
device intermittency.** T/√12 remains a long-run average floor, not a
per-window discriminator by itself.

```bash
python3 tools/avsync_capture_beat.py \
  --report PATH/rk20_report.json --marker-period-s 2.0
echo "beat true rc=$?"
```

## Floor measurement (required before any device lipsync claim)

### MODE=file — algorithm floor only (NOT grabber) — host can run anytime

Host-measured now (AudioID 60s file):

| field | value | tag |
|-------|------:|-----|
| residual_rms_ms | **1.48** | instrument_floor |
| detrended_p95_abs_ms | **2.41** | instrument_floor |
| timing_class | STABLE | |

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
OUT=$PWD/avsync_hdmi_out/floor_file_$(date +%Y%m%dT%H%M%S)
MODE=file MARKER_PERIOD_S=2.0 MIN_PAIRS=15 OUT="$OUT" \
  bash tools/avsync_instrument_floor.sh
echo "floor_file true rc=$?"
```

### MODE=loopback — **grabber floor** (blocking) — YOU run

1. **Unplug DE10-Nano from MS2109 HDMI IN.**
2. Cable **host HDMI out → MS2109 HDMI IN** (host has `HDMI-A-1` + `DP-3`).
3. Play flash+beep fixture on that HDMI output (mpv/fullscreen or desktop).
4. `/dev/video0` free; `arecord -l` shows MS2109 `hw:0,0`.

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
fuser -v /dev/video0 || true
# Play fixture on the HDMI port feeding the grabber (manual or):
#   HDMI_OUT=HDMI-A-1 mpv --fullscreen assets/avsync/sync_audio_id_glass_480p24_60s.mp4
OUT=$PWD/avsync_hdmi_out/floor_loop_$(date +%Y%m%dT%H%M%S)
MODE=loopback DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 \
  LABEL=loop OUT="$OUT" \
  bash tools/avsync_instrument_floor.sh >"$OUT/wrap.txt" 2>&1
echo "floor_loop true rc=$?"
grep -E 'residual_rms|detrended_p95|timing_class|VERDICT|floor_' "$OUT/wrap.txt" "$OUT"/loop_*stdout.txt
```

**Pre-reg (publish hit/miss):**

| ID | Prediction |
|----|------------|
| F1 | loopback n_pairs≥20, not DISPLAY_FLAT |
| F2 | loop residual_rms **≥** file residual (~1.5) — grabber adds noise |
| F3 | loop residual is the **device-claim floor**; live DE10 residual only attributable if clearly above F3+margin |
| F4 | beat model on loop report still prints; tag all as `instrument_floor` |

Until F1–F3 land, **do not publish device lipsync residual as a defect.**

## After floor exists

Only then: **N≥8** windows per class for rate claims. Not before.

## Scorer change (committed)

- Headline: **`detrended_p95_abs_ms`**
- `detrended_max_abs_ms` kept, labelled **fragile_n1_tail_not_headline**
- SCORE line includes p95

## Out of scope (settled)

Frame drops / inter-frame ~41.7 vs ~83 ms → **w-instr**. Not this lane.
