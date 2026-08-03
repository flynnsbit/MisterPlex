# Ascal: does input V_TOTAL dither reach the sink?

## Pre-register (before deep read — rule 0)

| # | Prediction | Confidence |
|---|------------|------------|
| P1 | ascal is a **framebuffer** scaler: input write and HDMI output rasters are **decoupled** by RAM | medium-high |
| P2 | Default product uses **triple buffer** (`mode[3]=1` when `lowlat=0`) so varying input frame period is absorbed as buffer occupancy, not HDMI vsync jitter | medium |
| P3 | Default **VRR off** (`vrr_mode=0`) → output OSWEEP free-runs on `o_htotal`/`o_vtotal` from HDMI config, not core beam V_TOTAL | medium |
| P4 | `iauto` size is DE-only; V blanking 705↔706 with **fixed V_ACTIVE** does **not** change `ih/iv` and does **not** trip size-only `swblack` | high (prior blanking gate) |
| P5 | If `lowlat=1` (single buffer) or `vrr_mode=1`, absorption claim weakens — must gate product path | medium |

**Miss policy:** quote contradictory VHDL/ports; flip verdict; no invented HW proof.

## Measured (after read)

### Architecture: framebuffer, not line-locked passthrough

- Header: `MODE[3] 0=Direct single FB, 1=Triple buffering` (`ascal.vhd:89-90`).
- Input end-of-frame: `i_endframe*` from **input** `i_vs` (`~1256-1258`).
- Buffer advance on input edge; output takes new buffer on **output** VS fall
  (`~1933-1937`: `o_vsv` edge → `o_obuf*`).
- **Output sweep is free-running** on `o_clk` (`OSWEEP ~2763-2793`):
  `o_hcpt`/`o_vcpt` vs `o_htotal`/`o_vtotal` from HDMI timing ports — **not**
  core `V_TOTAL`.

### Product defaults (`sys_top.v`)

```
reg lowlat   = 0;     // → mode = {~lowlat,...} → mode[3]=1 triple buffer
reg vrr_mode = 0;     // VRR off
.mode ({~lowlat, LFB_EN ? LFB_FLT : |scaler_flt, 2'b00})
.vrr  (vrr_mode)
.iauto(1)
```

Quoted: `sys_top.v:329,336,758,787,791`.

### VRR path (when enabled) *does* couple

`o_vrr_sync` can hold `o_vcpt_pre3` at `o_vsstart` waiting for input isync
(`~2772-2775`, `~2816-2826`). With `vrr_mode=0` this path is inactive.

### iauto + swblack (size only)

- `i_himax` from DE fall; `i_hmax<=i_himax` under iauto (`~1263-1276`).
- `swblack` triggers on `o_ihsize /= i_hrsize or o_ivsize /= i_vrsize`
  (`~1951-52`) — **active size**, not beam V_TOTAL.
- Fixed V_ACTIVE + dithered V blanking → same ih/iv → no blackout from dither alone.

## Verdict (evidence-backed, scope-limited)

| Condition | Input V705/706 dither absorbed? |
|-----------|----------------------------------|
| Default product: `lowlat=0`, `vrr_mode=0`, progressive | **YES — HDMI output timing independent; FB triple-buffer absorbs arrival jitter** |
| `vrr_mode=1` | **NO claim** — output can stretch to input isync |
| `lowlat=1` (single FB) | **WEAK** — same buffer; tearing/underrun risk under rate mismatch; do not call free |
| Glass / capture proof | **UNKNOWN** — no device; arithmetic + RTL only |

**Option D vs C (priority-corrected):** Under default ascal config, **Option D
(2-value V_TOTAL dither on core beam) is arithmetically exact long-run and
ascal-absorbed on the HDMI side** — it beats C for fabric-owned cadence *if*
implemented with a pending-bank model and product gates that **force**
triple-buffer / VRR-off (or fail closed). This is **not** a 720p fit blocker;
rank (c) after fit + present path.

## What is still NOT proven

- No STA of a dither FSM.
- No long-haul unique-bank model under dither + ARM fill.
- No HDMI capture of 59.1 µs period jitter (should be zero at sink if FB path).
- `fps_1001` still not on wire (ABI #4).

## Gates

- Blanking DE-only: `tests/unit/test_ascal_iauto_de_only.sh` (existing)
- This absorb contract: `tests/unit/test_ascal_vsync_dither_absorb.sh`
- Product defaults: assert `lowlat` reset 0, `vrr_mode` reset 0, mode triple bit
