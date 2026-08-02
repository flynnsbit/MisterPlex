# rk30 long real-content soak — parent-run protocol (power-aware)

**Asset:** rk=**30** `MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4`  
**On-disk:** 624×480, **24/1**, Constrained Baseline L3.0, B=0, video ~2454 kbit/s,
total ~2621 kbit/s, AAC, **1200.000 s**, glass ID + A/V markers.  
**Asset fps truth:** ffprobe **24/1**. Quote PMS `frameRate` if present; never assume 23.976.

Agent does **not** cast.

## Why length is not “pick a nice number”

Parent measured **~25% session-level degraded event rate** on the same asset
(consecutive runs, nothing changed). Session-mean A/B is retired; this soak still
needs enough **independent exposure** that a 25% process is likely to appear at
least once if it is real under DP.

Model (explicit, crude): treat each **~200 s** wall block as one Bernoulli trial
with \(p = 0.25\) (matches ~3–4 min runs where intermittency was seen).

| goal | formula | k blocks | wall @ 200 s/block |
|------|---------|----------|--------------------|
| ≥1 event, **80%** power | \(1-0.75^k \ge 0.80\) → \(k \ge 6\) | **6** | **~1200 s** |
| ≥1 event, **95%** power | \(1-0.75^k \ge 0.95\) → \(k \ge 11\) | **11** | **~2200 s** |

**rk30 single play = 1200 s ≈ k=6 → ~80% chance of ≥1 degraded block if p=0.25.**  
That is the minimum honest one-shot soak. For 95%, either:

- play rk30 **twice back-to-back** (2400 s), or  
- loop / second title with same encode family.

If DP is not held, **VOID** — do not burn 20 minutes on universal confound.

## Conf / resolve (mandatory)

```text
PREFER_DIRECT_H264=1     # and/or STREAM=1; plus w-cpu-1 floor fix if still on universal
```

**PASS resolve:**

```text
misterplexd: PREFER_DIRECT_H264=1 ...
misterplexd: resolved direct H.264 Part ... transcode=0
misterplexd: GEOM ... transcoded=0 library_media=624x480
```

Host:

```bash
./scripts/sample_host_load_for_cast.sh 1210 2 .agent-work/hostload_rk30_soak.tsv
TOK=$(cat /tmp/local_tok.txt) ./scripts/prove_directplay_host.sh 30
```

## Sampling (feeds within-run instrument)

| phase | wall | action |
|-------|-----:|--------|
| T0 | 0 | cast; confirm DP within 10 s |
| Startup exclude | 0–15 s | exclude from supply_iv / event labels |
| Core | **15 → 1200 s** | full asset; primary |
| Optional power-up | second cast 0→1200 | if first play had zero degraded blocks and you need 95% |
| Sample period | **≤2 s** (100 ms if harness allows) | supply, drops, dframes, hostload |
| Block labels | every **200 s** wall after T0 | mark block degraded/healthy for p̂ |

**Block degraded (pre-registered definition — publish miss if you change it mid-run):**

```text
block_supply_iv = Δaudio_s / Δwall_s over that 200 s
DEGRADED if block_supply_iv < 0.90 OR Δdrops in block ≥ 100
HEALTHY  if block_supply_iv ≥ 0.95 AND Δdrops < 50
else     AMBIGUOUS (count separately; not in p̂ numerator/denominator)
```

## Pre-registered criteria

| ID | prediction | PASS | MISS |
|----|------------|------|------|
| S1 | DP entire soak | all resolve/GEOM `transcode=0`, tc_max=0 | any universal |
| S2 | Geometry | `measured=624x480` | height ≤360 w/o SAR RCA |
| S3 | Full-window supply | overall supply_iv **≥ 0.90** | overall < 0.85 (link starve candidate: source ~2.6 Mbit > 1.15 path) |
| S4 | Intermittency visible | if any DEGRADED block: recovery to HEALTHY without conf change | single-step permanent collapse only |
| S5 | Cadence when healthy | dframes/dwall ∈ 23.5–24.5 on HEALTHY blocks | <22 on HEALTHY supply |
| S6 | Event rate | report p̂ = n_DEG / n_(H∪D); **no pass/fail on p̂** — descriptive | — |
| S7 | Power note | if zero DEGRADED in 1200 s DP: state “consistent with p≪0.25 **or** DP removed the process; need 2nd play for 95%” | claiming “no intermittency” from one clean 1200 s alone |

**Joint**

- **REAL_SOAK_DP_HEALTHY:** S1∧S2∧S3∧S5, zero DEGRADED blocks  
- **REAL_SOAK_DP_INTERMITTENT:** S1∧S2∧S4 with ≥1 DEGRADED + ≥1 HEALTHY  
- **LINK_STARVE:** S1∧S2∧¬S3 (expected-ish at 2.6 Mbit DP — publish)  
- **VOID:** ¬S1  

## Report shape

```text
rk=30 DP=1 wall_s=... overall_supply_iv=... measured=...
blocks: H=... D=... A=... p_hat=...
load1_p50=... plex_cpu_p95=... tc_max=0
verdict=REAL_SOAK_DP_HEALTHY|REAL_SOAK_DP_INTERMITTENT|LINK_STARVE|VOID
```
