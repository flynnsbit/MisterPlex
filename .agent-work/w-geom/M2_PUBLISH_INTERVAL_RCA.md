# M2 — RETRACTED as named mechanism (see ERROR_21_M2_RETRACTION.md)

**Do not treat this file as an active RCA.** Parent ERROR 21 (2026-08-01) retracted
M2 as the surviving mechanism. Historical text below is retained only as a miss
record and design notes for optional telemetry — **not** a device defect claim.

**Active position:** no device-side lipsync/judder defect established from the
two paired windows; unknown is correct. Standing lane = FORCE_SCALE / B1 / B5.

---

## M1 MISS (published — STILL VALID)

| Pre-reg M1 | Measured |
|------------|----------|
| WANDER ⇒ `vfps_p50≤20` | **vfps = 23.9** all 108 samples |
| WANDER ⇒ `Δdrops≥15` | **Δdrops = 0** (flat 11) |

**Verdict: M1 UNDERPRODUCE_THEN_DROP is FALSIFIED** for this defect class.  
Under-production remains a *possible other* failure mode; it is **not** the mechanism of the paired WANDER.

Correlator now tags `M1_FALSIFIED_high_vfps_flat_drops` on that shape.

---

## What survives: M2

Frames are produced and pacer-presented on time (`vfps≈pfps≈24`, drops flat), yet glass A/V offset **wanders**.  
That is **presentation timing irregularity** invisible to `vfps`/`drops`/`clock=av-lock` (hardcoded).

Intermittency constraint: **any mechanism must fire with constant ledger throughput** (STABLE↔WANDER in one session).

---

## Source mechanisms (quote, then prove/kill)

### M2a — ARM publish **arrival** phase beat vs 60 Hz vsync (PRIMARY candidate)

| Fact | Citation |
|------|----------|
| Swap only on `vsync_pulse && swap_pending && pending_ready` | `ddr_frame_store.sv` (product present path) |
| ARM doorbell is **async free-gate** — no wait-for-vsync | `media_player.cpp` `publishDdrFrame` → `fpga_.publishDdrFrame` |
| Hold on glass = vsyncs until next swap | function of (publish phase relative to vsync) × (inter-publish interval) |
| Ideal content period 24.000 → **41.666… ms**; display 60 Hz → **16.666… ms** | beat: 5 display periods = 2 content periods |

**Intermittency:** slow phase walk of publish pre-timestamps vs vsync can move between “good 2/3 hold pattern” and “occasional 1-refresh + catch-up” without changing mean fps.  
**Predict:** rolling `pub_iv_p_ge50_w60` **elevated on WANDER**, **low on STABLE**; `disc=LATE_ARRIVAL`; `write_us` flat.

### M2b — `publishDdrFrame` **write** latency spikes (DDR/memcpy/contention)

| Fact | Citation |
|------|----------|
| pre/post stamps around write | `media_player.cpp:766-778` `pubInterval_.note(preUs, postUs)` |
| Discriminator | `publish_interval_ledger.hpp` LATE_OBSERVATION = clean arrival + fat write |

**Intermittency:** sched/IRQ/DDR contention bursts.  
**Predict:** WANDER with `pub_iv_disc_w60=LATE_OBSERVATION`, `pub_iv_write_max_us_w60` large, `p_ge50_w60` clean.

### M2c — Scheduler preemption of publish thread **between** frames (not inside write)

Same as M2a in arrival space: pre-to-pre stretches, write flat → LATE_ARRIVAL.  
Split from pure vsync beat by **acf**: clustered lates (positive lag1) vs long-then-short (negative lag1). Session_end `publish_interval_acf` already exists.

### M2d — Scanout/DDR bank contention with refill

Would show as write fat and/or publish_misses rising.  
**Kill if:** `publish_misses` stays 0 and write_max low on WANDER.

### M2e — Audio path phase only (video metronome clean)

**Predict:** WANDER + `pub_iv_p_ge50_w60` clean + disc CLEAN.  
That **misses M2a/b** and redirects to audio/MrAudio (coordinate w-avsync / audio lane).

---

## Instrumentation (tip)

| Field | Where | Meaning |
|-------|--------|---------|
| `pub_iv_p_ge50_w60` | 1 Hz `media:` line via `formatHzFragment()` | P(arrival_iv>50ms) over last ~1440 intervals (~60s) |
| `pub_iv_max_ms_w60` | same | worst gap in window |
| `pub_iv_disc_w60` | LATE_ARRIVAL / LATE_OBSERVATION / CLEAN / MIXED | write vs arrival split |
| `pub_iv_p_ge50_w5` | ~5s roll | burst detector |
| `pub_iv_sess_p_ge50` | session cumulative | long-term |
| full hist/acf | `phase=session_end` or `MISTERPLEX_PUBLISH_INTERVAL_LOG=1` mid | deeper |
| dump `pre_us,write_us` | `MISTERPLEX_PUBLISH_INTERVAL_DUMP=path` at session_end | raw series |

**Why `av_display_offset_ms` / `publish_misses` were NO-DATA on your pair:**  
Live daemon log schema was **old**:

```
media: frames=… vfps=… pfps=… audio_s=… wall_s=… clock=av-lock av_drift_ms=… drops=…
```

Tip emits `frameLedgerTelemetryFragment` + `formatAvServoTelemetry` + **`formatHzFragment`**.  
**Deploy tip ARM** (rebuild after this commit) — not a correlator bug.

---

## Pre-register (before N≥6)

| Window class | `pub_iv_p_ge50_w60` | disc | Implies |
|--------------|-------------------:|------|---------|
| WANDER | **≥ 0.03** (pref ≥0.05) | LATE_ARRIVAL | **M2a/c HIT** |
| WANDER | **< 0.03** | LATE_OBSERVATION + write_max high | **M2b HIT** |
| WANDER | **< 0.03** | CLEAN | **M2e** (publish clean; not ARM doorbell cadence) |
| STABLE | **< 0.03** | CLEAN | control OK |
| STABLE | **≥ 0.09** | any | **MISS** — interval late without glass wander |

Also: WANDER rate among N windows is itself a measured quantity (no prior claim).

---

## 240p control

Same N-window protocol at `DECODE=320x240` (or user 240 tier).  
**Predict if tier-independent:** similar WANDER fraction and p_ge50 coupling.  
**Predict if 480p-specific:** WANDER rate or p_ge50 coupling only at 624.  
(Push bytes are identical 449280 — if 480p-only, look past memcpy size: decode load, PMS tier, audio.)
