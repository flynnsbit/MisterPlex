# p480-audio — sustained soak + A/V (both tiers)

- **TS_UTC**: 2026-07-30T16:51–17:05Z approx
- **SOURCE_SHA**: see `SOURCE_SHA.txt`
- **Instrument**: `tests/hw/test_p480_ab_harness.sh` (p480-ab)
- **CPU method**: `P=100*dticks/(HZ*dwall)` — no fps scaling; per-thread + nvcsw/nivcsw
- **Clip**: PMS `.41` `/library/metadata/12` Sync 24000 Long Blip, offset=0, 24/1, transcode
- **Window**: settle=25s, measure=180s (same both tiers)
- **RBF**: `14eaeff3` unchanged · daemon `fb9f7619`

## Pre-registered predictions

See `predictions.txt`. Results below.

## Sustained metrics (180s)

| Tier | coded | mplex %onecpu | ffmpeg %onecpu | vfps_mean | pfps_mean | drops_delta | av_drift mean | drift late−early | DDR push mean |
|---|---|---|---|---|---|---|---|---|---|
| **240p** | 320x240 | **8.461** | **13.764** | 23.725 | 23.698 | **0** | −30.4 ms | **+1.62 ms** | 4.06 ms |
| **480p** | 624x480 | **20.79** | **69.022** | 23.714 | 23.484 | **1** | −29.8 ms | **−1.60 ms** | 8.52 ms |

Artifacts: `p480_ab_240p_*` and `p480_ab_480p_*` json/kv/table/log/frames/cpu.

### Drops: bounded, not growing

From log thirds (`fps_gap_and_bounds.txt`):

| Tier | early drops | mid | late | window drops_delta |
|---|---|---|---|---|
| 240p | 1→1 | 1→1 | 1→1 | **0** |
| 480p | 7→8 (startup) | 8→8 | 8→8 | **1** |

480p extra drops are **front-loaded**; mid+late flat at 8. **Not** 5→50 growth.

### A/V drift: holds, bounded

- Both tiers lock `clock=av-lock`, mean drift ≈ **−30 ms** (constant offset, not runaway).
- late−early over ~180s: **±1.6 ms** → slope ~0 (bounded).
- One early `A/V resync drop` each tier at session start; no underrun storm in window.
- **HDMI flash↔beep path UNSCORED**: grabber mean_luma=**7.0** (black) during play; `avsync_rate` → `flashes=0 beeps=0`. Product A/V claim rests on **daemon av_drift_ms**, not HDMI lipsync.

## ~23 vs 24 fps gap

**Evidence-backed explanation (partial):**

1. **pfps/vfps are cumulative** from session t0 (`media_player.cpp` ~2927–2934): `1000*count/wall_ms`. Early startup lag permanently pulls the average.
2. **Thirds prove it**: late third both tiers → `pfps_last=23.9` / `vfps=23.9` (early 240p pfps_mean=23.3; early 480p=22.8).
3. **Log prints only 4 chars** (`std::to_string(vfps).substr(0,4)`), so values in [23.90, 23.999] all show as `23.9`. Exact residual below 24.0 is **not fully resolved without higher-precision logging** — but the gap is **not 480p-specific** and **not a 1 fps sustained loss**.

## Real Plex UI cast — handoff

**Could not drive the real Plex client UI headlessly** this session (no authenticated Plex Web/TV session automation).

API/`playMedia` path: proven working (prior p480-verify + these soaks).

**User click path to close the UI question:**

1. On a Plex client signed into the **real** server (`192.168.1.41`, not localhost empty PMS).
2. Confirm MiSTer appears as cast target **MiSTerPlex** / `misterplex-dev`.
3. Ensure MiSTer OSD shows **Plex** core loaded (`CORENAME=Plex` — if Menu, daemon logs say cast "doesn't stick").
4. Cast any library item → should stay on MiSTer with playing timeline.
5. Optional: F12 → Content resolution → 640x480 for 480p coded 624x480; default leave 320x240.

## Device left as

| Item | Value |
|---|---|
| daemon | fb9f7619 + supervise n_d=1 |
| RBF | 14eaeff3 |
| CORENAME | Plex |
| OSD_CONTROL | 1 |
| DECODE conf | 320x240 |
| PRESENT_PROFILE | 0 |
| O[4] / tier | **240p** (bit4=0, status 0x4000) |

## Prediction scorecard

| ID | Result |
|---|---|
| P1 drops 240p bounded | **HIT** (delta 0) |
| P2 drops/drift 480p bounded | **HIT** (delta 1; drift slope ±1.6ms) |
| P3 pfps gap startup avg | **HIT** (thirds + cumulative formula) |
| P4 HDMI may unscored | **HIT** (black grabber) |
| P5 UI handoff | **HIT** (handoff written) |
| P6 supervise race | mitigated (stopped for run; restored) |
