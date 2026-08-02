# 480p intermittent throughput / lipsync WANDER — pre-register (w-geom)

**SHA at write:** see `git rev-parse HEAD`  
**Scope:** source + host correlator only. Parent runs device.  
**Does not own:** w-avsync instrument internals; w-cpu-1 PIPE_DESYNC trip triage.

---

## Settled non-causes (do not re-open without new evidence)

| Claim | Why dead for THIS defect |
|-------|---------------------------|
| Raw-pipe desync / wrong I420 size | Parent: `measured=624x480 desync_risk=0` |
| DDR push bytes unique to 480p | Both tiers publish **449280** (`ddr_frame_layout.hpp`) |
| “480p is ARM decode CPU-blocked” | Parent ERROR 15 retracted; headroom **9.57×**; H.264 ~5.8 %onecpu |
| `clock=av-lock` means lipsync healthy | **Hardcoded string** every 1 Hz line (`media_player.cpp` log fragment `clock=av-lock`). Not a mode bit. |
| `av_drift_ms` is lipsync | `av_drift_role=servo_error_not_lipsync` (`av_clock.hpp` `formatAvServoTelemetry`); steady lock sits near `−lead` **by construction** of `avDecide` Hold |

---

## Arithmetic on parent’s live line (quoted)

```
frames=1973 vfps=18.3 pfps=17.6 audio_s=82.40 wall_s=107.7
clock=av-lock av_drift_ms=-39 drops=70 fps=24/1 decode=624x480 measured=624x480 desync_risk=0
```

| Quantity | Value | Derivation |
|----------|------:|------------|
| expected @24 | 2584.8 | `wall_s * 24` |
| under_prod | **~612** | `expected − frames` |
| content_video_s | 82.21 | `frames/24` |
| content_audio_s (submitted) | 82.40 | log `audio_s` |
| pfps gap | 0.7 | `vfps − pfps` |
| drops/wall | **0.65** | `70/107.7` |

**Rule-0 statement:** `vfps − pfps ≈ drops/wall` on this sample. The “present side degrades worse” observation is **almost entirely pacer `AvAction::Drop`**, not an extra DDR failure class. Residual `frames − presents − drops` is small (~single digits if pfps is exact).

`av_drift_ms=-39` with lead≈40 is **servo deadband**, not external 224 ms.

---

## Pre-registered mechanisms (predict BEFORE paired capture)

### M1 — RETIRED / FALSIFIED (parent pair 2026-08-01) — `UNDERPRODUCE_THEN_DROP`

**MISS published:** HDMI WANDER with `vfps=23.9` rock-flat and `drops_delta=0` (n=108).  
M1 predicted `vfps_p50≤20` and `Δdrops≥15`. **Primary is now M2** — see `M2_PUBLISH_INTERVAL_RCA.md`.

### M1 — (historical text kept for the miss record)

1. Intermittent **frame under-production** (`frames/wall < 24`) for reasons **not yet split** (delivery / sched spike / present backpressure — capture decides).
2. When audible clock pulls ahead of `frameIndex`, `avDecide` returns **Drop** (`av_clock.hpp`: `drift > dropMs && dropRun < maxDropRun`).
3. Drops lower `presentCount` vs `frameIndex` → `pfps < vfps` by ~`drops/wall`.
4. Glass flash phase becomes irregular → grabber **WANDER** (`residual_rms` / `detrended_max_abs`) even while daemon prints `clock=av-lock` and `av_drift_ms≈−lead`.

**Predict on WANDER runs:** mid-window `vfps` p50 **≤ 21**, `Δdrops` over window **≥ 15**, `av_display_offset_ms` **worsens** (grows away from 0 in magnitude) vs STABLE twin.

**Predict on STABLE runs:** `vfps` p50 **≥ 23.2**, `Δdrops` **≤ 5** after startup region (`wall_s>10`).

### M2 — SECONDARY — `PUBLISH_INTERVAL_JITTER`

Irregular doorbell cadence (`publish_interval` / `p_ge50`) with **healthy** vfps causes hold jitter → WANDER without large under_prod.

**Predict if M2 alone:** WANDER + `vfps≥23.2` + `Δdrops≤5` + `publish_interval` verdict `ARM_LATE_*`.

### M3 — KILLED unless capture resurrects — `DDR_BYTE_COST_480P`

Same 449280 both tiers. Cannot explain 480p-specific collapse by memcpy size alone.

### M4 — NOT claimed — `IDENTITY_SKIP_CPU_PARADOX`

Bank-exact 480p with FORCE_SCALE policy is **cheaper or equal** on scaler than 240p upscale once verified; parent’s historical “identity cheaper yet worse” is **not** a scaler-cost proof. Do not use it as mechanism without present_profile proof.

---

## Falsifiers (paired window only)

| ID | Observation in **same** HDMI window | Verdict |
|----|-------------------------------------|---------|
| F1 | WANDER + vfps_p50≥23.5 + Δdrops≤3 + publish CLEAN | **M1 and M2 both miss** — new class |
| F2 | WANDER + vfps_p50≥23.5 + publish ARM_LATE | **M2 hit; M1 miss** |
| F3 | WANDER + vfps_p50≤20 + Δdrops≥15 | **M1 hit** |
| F4 | F3 + `present_profile` `ddr_wait_us_p` high + pipe full signals | M1 root = **present stall → backpressure** |
| F5 | F3 + ddr clean + ffmpeg `agg_wait_frac` high | M1 root = **CPU sched** (hand w-cpu-1) |
| F6 | F3 + ffmpeg cold + delivery gaps | M1 root = **net/PMS** |
| F7 | STABLE twin same binary/asset within 10 min | confirms **intermittent**, not conf |

**Publish misses after parent runs.**

---

## What to LOOK AT on glass / in artifacts

1. `timing_class` + `residual_rms_ms` + `detrended_max_abs_ms` (HDMI — ground truth).
2. Same-window daemon: `vfps`, `pfps`, `drops`, `publish_misses`, `av_display_offset_ms`, `av_pipe_ahead_ms`, `av_drift_ms` (servo only).
3. Optional: `PRESENT_PROFILE=1` → `ddr_wait_us_p`, `ddr_copy_us_p`, `read_us` (user conf — backup first).
4. Optional: `publish_interval` session_end line after stop.

Do **not** treat `clock=av-lock` or `av_drift_ms≈−40` as PASS.
