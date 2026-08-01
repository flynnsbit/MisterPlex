# 480p glass frame loss — stage attribution (A1–A5)

**Finding (parent, pixel-confirmed):** 4 / 568 = **0.70%** steady-state source
frames absent on HDMI during 480p playback of a 24.000 fps burned-in counter
fixture. Not startup-only. Daemon `drops` can stay flat while glass loses frames.

**This agent does not touch the device.** Parent deploys, captures, scores.

## Already in tree (do not re-land)

| ID | Mechanism | Evidence in tree |
|----|-----------|------------------|
| A1 | `unaccounted = frames - presents - drops` on 1 Hz media line + session_end | `host/libmisterplex/frame_ledger.hpp` `frameLedgerTelemetryFragment`; `media_player.cpp` 1 Hz log |
| A2 | `publish_misses=` on same line; fail path logs `publish_misses=` | `publishMisses_` + fragment |
| A3 | Play-path ffmpeg `-loglevel info` + `-nostats` (Stream # WxH) | `media_player.cpp` raw-video spawn (~2995) |
| A4 | Teardown `rawPipeByteAligned` + `rawPipeDesynced` → `PIPE_BYTE_MISALIGN` / `PIPE_DESYNC` | `ffmpeg_vf.hpp` + teardown block |
| A5 | Servo vs display metrics (this change) | `av_servo_*`, `av_display_offset_ms`, `av_pipe_ahead_ms` |

Poison-macro guard for retracted `kParentClusterSepMsX100`: commit `63b98803`
(`#define` string poison before include + `test_av_phase_rtl_quanta_guard_red.sh`).

## Closed accounting (host)

```
unaccounted = frames - presents - drops     # residual; tag=measured
when every non-present is pacedrop OR publish-miss:
  unaccounted == publish_misses
```

**What residual cannot see:** frames ffmpeg never produced (never enter `frames`).
Those are glass holes with `unaccounted=0` and `publish_misses=0`.

## Pre-registered stage split (parent run)

Capture **≥90 s** 480p of the burned-in 24.000 fixture while logging daemon
stderr. Pull `misterplexd.frame_ledger` + log. Run glass ledger on PNG/pts.

```bash
# Host-side after parent pulls artifacts:
python3 tools/frame_ledger_report.py --log /path/daemon.log --ledger /path/misterplexd.frame_ledger
echo "true rc=$?"

python3 tools/glass_frame_ledger.py --png-dir /path/png --pts-csv /path/pts.csv \
  --src-fps 24/1 --src-fps-src caller_supplied
echo "true rc=$?"

# Grep measured fields (presence of keys, then values):
rg -n "unaccounted=|publish_misses=|PIPE_|MEASURED_DELIVERY|av_display_offset|av_servo_setpoint|session_epoch=" /path/daemon.log | head -80
```

### Predictions (falsifiable)

| Observation (all measured) | Stage attribution |
|----------------------------|-------------------|
| Glass holes **and** `unaccounted` rises ≈ hole count ×1, `publish_misses≈0` | Upstream of/at present accounting but **not** DDR fail — pacer/path skipped present without counting drop, or double-count bug |
| Glass holes **and** `publish_misses` rises, `unaccounted == publish_misses` | **DDR publish fail** (A2). Residual explained |
| Glass holes **and** `unaccounted=0`, `publish_misses=0`, `drops` flat | **Supply loss before frameIndex** (ffmpeg/PMS/pipe never delivered) **OR** **post-present scanout** (DDR/RTL). Host ledger cannot split (a) vs (c) — need bitstream/ recon counters or fabric |
| `PIPE_DESYNC=1` or `PIPE_BYTE_MISALIGN` | Raw pipe geometry/byte phase (A4) — treat as hard fail before other RCA |
| `delivery_verified=0` / no MEASURED_DELIVERY | A3 banner parse failed — geometry untrusted |

**Steady-state window:** ignore first 10 s wall_s (startup drops). Require single
`session_epoch` for the window (P4).

## A5 — unpinned vs servo (lipsync host metrics)

| Field | Role |
|-------|------|
| `av_drift_ms` / `av_servo_error_ms` | Control error on **frameIndex**; pinned near `-lead` |
| `av_servo_setpoint_ms` | `-AV_PRESENT_LEAD_MS` |
| `av_servo_margin_ms` | `drift + lead` (0 ≈ hold line) |
| `av_display_offset_ms` | Audio vs **presentCount** content time — drops do not auto-heal this |
| `av_pipe_ahead_ms` | Pipe content not yet presented |
| grabber (`avsync_measure_hdmi.py`) | **Only** lipsync GT |

### Falsifier — `AV_PRESENT_LEAD_MS=20` (was 40)

Pre-register before deploy:

1. **If `av_drift_ms` is setpoint readout (expected):** steady median moves by
   **≈ +20 ms** (e.g. −30 → −10), band ±8 ms; `av_servo_setpoint_ms=-20`.
2. **`av_display_offset_ms`:** not required to equal `-lead`; if it moves lock-step
   with setpoint while glass lipsync (grabber) does not, it is still servo-coupled.
3. **Grabber median:** independent GT. Lead change *may* move presentation phase
   ~Δlead; do not treat host `av_drift_ms` as confirming lipsync.

```bash
# On device conf (parent only):
# AV_PRESENT_LEAD_MS=20
# redeploy daemon, 60s soak, capture 1 Hz lines + optional grabber run
```

## Frame-rate note

Fixtures for this RCA are **`frameRate=24.000`**, not 23.976. Always pass
`--src-fps 24/1` with `src-fps-src=caller_supplied` (or measure with ffprobe).
Never print a hardcoded 23.976 beside measured values.
