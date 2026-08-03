# Budget attack results — 960×540 @30 (2026-08-03)

Lane: **w-path**. Worktree: `MisterPlex-wt-path` / branch `w-path-720p`.
Pre-reg: `BUDGET_ATTACK_PREDICTIONS_20260803.md`. Probe log: `probe_run/budget_attack_probe.txt`.
Parent device baseline (authority for totals): **decode+sws+raw 26.08 + copy 8.42 = 34.50 ms** vs **33.333 @30 → FAIL −1.17**.

**Constraint held:** `ddrFrameGeometryForFpgaPresent` still routes through `ddrStorageGeometryForContent` (540/360/720 identity). Not modified this segment.

---

## Task 1 — Threading / stage split

### Code fact (quoted)

`arm/misterplexd/media_player.cpp` builds a **CLI FFmpeg subprocess**. Grep for `-threads` / `thread_count` / `thread_type` in that file: **no matches**. There is no `AVCodecContext` in the product path.

Product raw path (FPGA present) forces **yuv420p** (`wantYuvDdr` → `RawVideoFormat::Yuv420p` → `-pix_fmt yuv420p`).

### What FFmpeg actually does with no `-threads`

| label | child CPU ms/f | wall ms/f | CPU% of 1 core |
|-------|---------------:|----------:|---------------:|
| **null_default** (no flag) | 0.778 | 0.233 | **334.2%** |
| null_t0 (`-threads 0`) | 0.776 | 0.224 | **346.6%** |
| null_t1 (`-threads 1`) | 0.559 | 0.475 | 117.7% |
| null_t2 (`-threads 2`) | 0.652 | 0.373 | 174.7% |
| **raw_id_default** | 1.377 | 12.097 | 11.4% |
| raw_id_t0 | 1.338 | 13.214 | 10.1% |
| raw_id_t1 | 1.183 | 18.318 | 6.5% |
| raw_id_t2 | 1.329 | 19.234 | 6.9% |

`ffmpeg -benchmark` rtime (360 frames, null sink, host):

| mode | rtime | utime | note |
|------|------:|------:|------|
| **default (no flag)** | **0.057 s** | 0.254 | multi (rss ~106 MiB) |
| `-threads 0` | 0.136 s | 0.306 | multi |
| `-threads 2` | 0.178 s | 0.224 | worse wall than default |
| `-threads 1` | 0.190 s | 0.200 | single-thread wall |

**Finding:** product default **already multi-threads** the h264 decoder (matches auto / ≫1 core). Explicit `-threads 2` does **not** beat default wall time. Forcing `-threads 1` is a large regression (bench rtime ~3.3× default).

### Stage split (host child-CPU ratios → parent 26.08)

Method: `ffmpeg_cpu_probe` on validated `proxy_960x540_30.mp4`, 360 frames.

| stage | method | host CPU ms/f | ratio vs null_t0 | device-class est. of 26.08 |
|-------|--------|--------------:|-----------------:|---------------------------:|
| decode (null sink) | `-f null` | 0.776 | 1.000 | **~15.11 ms** |
| + pack/raw I420 identity | raw yuv420p out | 1.338 | 1.725 | pack/pipe **~10.97 ms** |
| + forced scale (same WxH) | scale=960:540 | 1.425 | 1.838 | scale tax **~+1.7 ms** on path |
| + RGB24 instead of I420 | pix_fmt rgb24 | 2.424 | 3.126 | if product were RGB: **~+21 ms** on 26.08 class |

Parent total still: **26.08 + 8.42 copy = 34.50**. Copy is outside FFmpeg child.

### Threading vs 33.333 budget

| hypothesis | total vs 33.333 | verdict |
|------------|-----------------|--------|
| Product already multi (measured) | 34.50 | **FAIL −1.17 unchanged** |
| Optimistic “wire -threads 2” on already-auto path | raw_id t2/t0 CPU ≈ 0.99 | **no unlock** |
| Counterfactual if product were single-thread (it is not) | even large decode cut leaves copy 8.42 | still tight / likely fail |

**Do not wire `-threads 2`.** Optional explicit `-threads 0` is documentation-only; default already matches. No code change this segment.

### Prediction scorecard (Task 1)

| id | prediction | result |
|----|------------|--------|
| P-thr-code | no thread_count / CLI subprocess | **HIT** |
| P-thr-default | default ≈ auto multi | **HIT** (334% CPU, matches t0) |
| P-thr-2 | ≤15% further win vs default | **HIT as miss-of-prize**: t2 **worse** wall than default |
| P-split | meaningful decode vs pack split | **HIT** (~58% / ~42% of FFmpeg path CPU) |
| P-540-30-thread-unlock | threading brings 540@30 under budget | **MISS** — already multi; 34.50 stands |

---

## Task 2 — Colour conversion / fabric move

### Product format today

FPGA present path stores **I420 / yuv420p**:
- `DdrFrameFormat::Yuv420p`
- FFmpeg `-pix_fmt yuv420p`
- Payload **960×540 → 777,600 B** (after libavcodec SPS crop; coded bitstream is 544 with bottom crop 4 — settled)

There is **no I420→RGB** on the product DDR path. RGB appears only for fb0/both edge cases.

### Convert cost (host)

| path | bench utime+stime | raw probe CPU ms/f |
|------|------------------:|-------------------:|
| yuv420p null | 0.287 s / 360f | — |
| rgb24 null | 0.431 s / 360f | — |
| raw I420 | — | 1.338 |
| raw RGB | — | 2.424 (**1.81×** I420) |

Device-class: if someone forced RGB on the 26.08 I420 path, expect roughly **+21 ms** — catastrophic. Product does not do this.

### DDR footprint

| format | 960×540 bytes | notes |
|--------|-------------:|-------|
| **I420 (product)** | **777,600** | frozen bank payload |
| RGB24 | 1,555,200 | 2× bytes + convert |
| Bitstream-coded 960×544 I420 | 783,360 | fabric-decoder / ring only |

### Recommendation

**Moving colour convert into the FPGA wins ~0 ms on the product path** — the prize is not there. libavcodec already hands I420; we already publish I420.

Remaining ARM cost that *could* move or shrink:
1. **DDR copy 8.42 ms** (parent) — WC/DMA / present path (not colour).
2. **FFmpeg pack/pipe ~11 ms device-class** — structural pipe+sws identity overhead; fabric decode would eliminate ARM decode+pack entirely (future).
3. **Decode ~15 ms device-class** — only leaves via smaller tier (360) or fabric decoder.

**Do not dispatch colour-to-fabric for this budget crisis.**

### Prediction scorecard (Task 2)

| id | prediction | result |
|----|------------|--------|
| P-fmt-product | already yuv420p | **HIT** |
| P-rgb-tax | large if RGB | **HIT** (~1.8× CPU) |
| P-colour-fabric-prize | small / zero on product | **HIT** — **zero** |

---

## Task 3 — PMS `video.frameRate=30` lever

Method: same as fr24 — `X-Plex-Client-Profile-Extra` upperBound on `video.frameRate`, MiSTerPlex profile, lab PMS, stream ffprobe `r_frame_rate`. Bodies deleted; decisions scrubbed.

| case | request Extra | source | delivered `r_frame_rate` | WxH |
|------|---------------|--------|--------------------------|-----|
| rk142 540 nocap | (none) | 29.97 | **30000/1001** | 960×540 |
| rk142 540 fr30 | upperBound **30** | 29.97 | **30000/1001** | 960×540 |
| rk142 540 fr24 | upperBound **24** | 29.97 | **24/1** | 960×540 |
| rk142 360 nocap | (none) | 29.97 | **30000/1001** | 640×360 |
| rk142 360 fr30 | upperBound **30** | 29.97 | **30000/1001** | 640×360 |
| rk2 540 fr30 | upperBound **30** | 24 | **24/1** | 960×540 |
| rk2 360 fr30 | upperBound **30** | 24 | **24/1** | 640×360 |

**Findings:**
1. Extra `video.frameRate=30` is a real **upper bound** mechanism (same knob as 24).
2. On a 29.97 source it **allows pass-through** (does not force 30.000 or 24). Delivered rate = source rate.
3. On a 24 source it does **not upsample** — stays 24.
4. Only Extra **24** forces a down-cap (judder trade). Query params remain inert (prior FPS report).

So for **native 30 fps delivery**: omit the 24 cap (or set Extra upperBound ≥ source rate). Lever is real; it does not create 30 from 24, and it does not by itself fix the 34.50 budget.

Artifacts: `probe_run/ba_rk142_*`, `ba_rk2_*`.

---

## Bottom line for parent

| question | answer |
|----------|--------|
| Are both A9 cores used? | **Yes** under product default (no `-threads`). ~3.3× wall vs forced single-thread on host bench. |
| Stage split of 26.08? | **~15.1 decode + ~11.0 pack/pipe** (ratio-mapped); **+8.42 copy** outside FFmpeg → 34.50 |
| Does threading unlock 540@30? | **No.** Already multi. Explicit t2 does not help. |
| Colour-to-fabric prize? | **None** on product — already I420 @ 777,600 B. |
| PMS fr30 Extra? | **Works as ceiling**; 29.97 passes; 24 stays 24. |
| 960×540 @30 vs 33.333? | **Still FAIL −1.17** on parent numbers. |
| What still fits @30? | **640×360 @30 ~18.05 ms** (+15.28). |
| What still fits detail tier? | **960×540 @24** (+7.16 vs 41.667) with Extra fr24. |

### Product recommendation (unchanged dual tier)

```
source ~24 fps  →  960×540 @24, 4/3 fabric     (detail; Extra fr24)
source ~30 fps  →  640×360 @30, exact 2× fabric (motion; no judder; budget clear)
```

Do **not** ship uncapped 960×540 on 29.97 as “720p glass” — it fails the deadline before glass quality is even scored.

### Remaining attack surface (not claimed done)

| lever | owner | notes |
|-------|-------|-------|
| Cut present/DDR copy 8.42 | w-mem / present path | only path that could clear −1.17 without dropping tier |
| Fabric decode | future | removes ~15+11 ARM |
| Keep dual tier | w-path (landed) | **ship path today** |

### Collision watch

`ddrFrameGeometryForFpgaPresent` = storage selector (w-path). If w-mem re-reverts to 624 canvas, **flag parent — do not silent-fix**.

---

## Evidence index

- Predictions: `BUDGET_ATTACK_PREDICTIONS_20260803.md`
- Probe matrix: `probe_run/budget_attack_probe.txt`
- PMS fr30: `probe_run/ba_*_{decision.xml,ffprobe.json}`
- Proxies: `probe_run/proxy_960x540_{24,30}.mp4`
