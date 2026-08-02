# rk30 long real-content soak — parent-run protocol

**Asset:** rk=**30** `MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4`  
**On-disk (ffprobe):** 624×480, **24/1**, Constrained Baseline L3.0, B=0, ~2454 kbit/s video,
total ~2621 kbit/s, AAC, duration **1200.000 s**, glass ID + A/V markers.  
**PMS:** `videoFrameRate` attribute often `24p` / `frameRate` may be None — **quote
ffprobe 24/1 as asset truth**; if PMS fills `frameRate`, quote that too (ERROR 17).

Agent does **not** cast. Parent runs all hardware.

## Conf / resolve (mandatory for clean soak)

```text
PREFER_DIRECT_H264=1          # or STREAM=1
# STREAM=0 + PREFER_DIRECT_H264 unset → always universal → VOID for “real DP soak”
```

**PASS resolve line:**

```text
misterplexd: PREFER_DIRECT_H264=1 (conf_set=1 STREAM=0)
misterplexd: resolved direct H.264 Part ... transcode=0
misterplexd: GEOM ... transcoded=0 library_media=624x480 ...
```

**VOID if** `transcode=1` / `PMS universal` — do not score as link/real-content DP.

Host companion during cast:

```bash
./scripts/sample_host_load_for_cast.sh 1210 2 .agent-work/hostload_rk30_soak.tsv
# optional eligibility preflight:
TOK=$(cat /tmp/local_tok.txt) ./scripts/prove_directplay_host.sh 30
```

## Duration / sampling

| phase | wall | action |
|-------|-----:|--------|
| T0 | 0 | cast rk30, confirm DP lines within 10 s |
| Startup exclude | 0–15 s | do **not** use for supply_iv / drop rate |
| Core soak | **15 s → 900 s** (15 min) | primary window (S5-scale) |
| Optional full | → 1200 s | if stable at 900 s |
| Sample | every 2 s | daemon supply / drops / dframes; hostload TSV |

Minimum publishable soak: **900 s wall after T0** with DP held entire time.
If cast dies earlier, report wall_s and why — do not pad.

## Metrics to record

From daemon (names as logged):

- `supply_ratio` end-of-run and **`supply_iv`** = Δaudio_s/Δwall_s over last 2/3 of window
  (`audio_s = audioBytes/(48000*4)`, `wall_s = wall_ms/1000` — media_player / supply_bucket)
- `dframes/dwall` (present or decode fps — same field used on AdvReal table)
- `drops` cumulative at end of window (and Δdrops over core window)
- `GEOM` `measured=` WxH, `transcoded=`, `identity_skip` if present
- Host: `load1_p50`, `plex_cpu_p95`, **`transcoder_procs_max` must be 0** on DP
- PMS `/transcode/sessions` empty for this title during run

HDMI optional (grabber may be dead): glass `n` monotonic via OCR later.

## Pre-registered criteria (publish miss if wrong)

**Context:** AdvReal DP-ineligible runs already showed **no stable bitrate knee**;
rk30 source ~2.6 Mbit/s **>** greedy path 1.15 Mbit/s, so under **true DP** this
soak is a **harsh link/real-content** probe, not a “should be easy” pass.

| ID | prediction | PASS if | MISS if |
|----|------------|---------|---------|
| S1 | Resolve stays DP entire soak | all GEOM/resolve `transcode=0`, tc_max=0 | any universal / tc≥1 |
| S2 | Geometry | `measured=624x480` (or library 624x480 with measured=624x480) | measured height ≤360 without RCA |
| S3 | Supply (DP) | `supply_iv` **≥ 0.95** over core window | supply_iv < 0.90 sustained |
| S4 | Intermittent collapse | no multi-minute excursion supply_iv < 0.85 | collapse then recover without conf change |
| S5 | Frame cadence | dframes/dwall ∈ **23.5–24.5** when supply_iv≥0.95 | systematic <22 with supply ok (decoder) |
| S6 | Drops | Δdrops / 900s **< 200** when S3 holds | Δdrops ≥ 1000 with S3 fail (starvation) |

**Joint verdict**

- **REAL_SOAK_PASS:** S1∧S2∧S3∧S5∧S6  
- **LINK_STARVE:** S1∧S2∧¬S3 (expected if 2.6 Mbit DP exceeds path — **publish**, actionable for bitrate cap)  
- **INTERMITTENT:** S4 miss — continue host-CPU / non-bitrate RCA  
- **VOID:** ¬S1  

If LINK_STARVE on DP rk30 but AdvReal 1800k DP was healthy, note delivered bitrate
differs (rk30 ~2.6M vs AdvReal capped encodes).

## Report shape (parent → thread)

```text
rk=30 DP=1 supply_iv=... dframes=... drops_delta=... measured=...
load1_p50=... plex_cpu_p95=... tc_max=0 wall_s=...
verdict=REAL_SOAK_PASS|LINK_STARVE|INTERMITTENT|VOID
```
