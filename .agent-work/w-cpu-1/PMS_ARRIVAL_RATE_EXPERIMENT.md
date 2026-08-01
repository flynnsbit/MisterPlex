# PMS HTTP arrival rate — parent experiment (w-cpu)

## Why (device facts you already measured — not repeated as new claims)

| Fact | Source class |
|---|---|
| ffmpeg null decode 624×480 CB 24 fps → `speed=9.57x` | parent-measured |
| product pipe `F_GETPIPE_SZ` = 2 MiB / ~4.67 frames | parent-measured |
| no `-re` on product ffmpeg argv | parent-measured / source |
| product `read()` blocks ~10.355 ms/f over 300 frames (pipe empty on arrival) | parent-measured |

**Do not use** `read_block + pacing_wait` split (rd-review: conserved by construction).

## Competing hypotheses → different observables

| Hypothesis | Observable | Predict |
|---|---|---|
| **H-PMS1x**: PMS HTTP body arrives ≈ stream bitrate (~456 kb/s ≈ 57 KB/s) | `Δrchar/Δwall` on **ffmpeg** pid | `ratio_vs_nominal ∈ [0.7, 1.5]` |
| **H-fast**: input arrives multi-× realtime; empty pipe is elsewhere | same | `ratio ≥ 2.5` sustained |
| **H-stall**: session not really feeding | same | `ratio < 0.4` or NO-DATA pid |

**Falsifier for “PMS delivers at ~1×”:** median `ratio_vs_nominal ≥ 2.5` over ≥ half of OK windows while `state=playing` and supply_bucket advancing.

**Supports H-PMS1x:** median ratio in [0.7, 1.5].  
Note: ratio≈1 supports **transcoder/session pacing**, not LAN bandwidth (57 KB/s ≪ GbE). Say which the number supports — do not upgrade to “PMS deliberately rate-limits” beyond “arrival tracks nominal bitrate”.

Primary counter: **`/proc/<ffmpeg-pid>/io` `rchar`** (includes socket `read()`).  
`read_bytes` often stays 0 for pure HTTP — treat as NO-DATA if both ends zero (instrument does this).

**Not** daemon `read_bytes_f` (that is rawvideo **pipe** reads after decode).

## PRE-REGISTER (fill before first sample)

```
PREDICT_median_ratio=________   # e.g. 1.0 for H-PMS1x
PREDICT_class_majority=PACE_1X|FAST_GE_2_5X|STALL_LT_0_4X
NOMINAL_BPS=57000               # override if PMS reports different videoBitrate
asset_bitrate_kbps=456          # caller_supplied from PMS / your note
```

## Commands (parent, on device, during REAL cast)

Session must be playing. Do **not** build a hand URL (HTTP 400 = NO-DATA).

```sh
# 0) Gate session (expect state=playing, time advancing) — use your usual status probe.
# 1) Copy script if needed, chmod +x
# 2) Run 10×1s windows. Resolve ffmpeg by exe only (ERROR 14).

cd /media/fat/misterplex  # or wherever you place the script
NOMINAL_BPS=57000 WINDOWS=10 WINDOW_S=1 \
  sh ./pms_arrival_rate_sample.sh
echo "true rc=$?"

# Optional: pin pid if multiple ffmpeg
# FFMPEG_PID=916 NOMINAL_BPS=57000 WINDOWS=10 sh ./pms_arrival_rate_sample.sh
# echo "true rc=$?"
```

Repo path: `tools/pms_arrival_rate_sample.sh`  
After daemon deploy from `w-cpu-fps-measure`, also expect log lines:

```
media: ffmpeg_io pid=… d_wall_s=… d_rchar=… rchar_Bps=… ratio_vs_nominal=… tag=measured
```

```sh
# From daemon log during same cast:
grep 'ffmpeg_io' /path/to/misterplexd.log | tail -20
echo "true rc=$?"
```

## Score card

| Result | Verdict |
|---|---|
| pace_1x_n ≥ ok_n/2 | **H-PMS1x supported** (arrival ≈ nominal) |
| fast_ge_2_5x_n ≥ ok_n/2 | **H-PMS1x FALSIFIED** — input multi-×; empty pipe needs other RCA |
| stall / NO-DATA majority | **NO-DATA** — fix session gate; do not conclude |

Publish misses vs PREDICT_*.

## Safety

- Read-only `/proc` + sleep. No kill, no core load, no conf write.  
- Daily driver safe.
