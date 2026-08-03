# 720p bus projection + 480p bitrate-margin audit

**Branch tip at write:** `da8c38eb` (parent of this commit may advance)  
**Lane:** ARM/host only — no device access  
**Instrument:** archived device `ddr_write_bench` in  
`build/arm-sleep-evidence/W-FEED-arm-profile-ORIGINAL.txt`  
plus FEED summary `build/arm-sleep-evidence/W-FEED-arm_profile_summary-ORIGINAL.txt`  
plus live A/B totals quoted from harness (parent / `docs/evidence/p720-scope-arm-*/REPORT.md`)

---

## Pre-registered predictions (before compute)

| ID | Prediction | After measure |
|----|------------|---------------|
| B1 | 1280×720 I420 = 1 382 400 B | **HIT** (exact `w*h*3/2`) |
| B2 | @ archive no-sync 59.521 MiB/s → ~22.1 ms copy | **HIT** (22.149 ms) |
| B3 | Bus alone does **not** block 24 fps (budget 41.67 ms) | **HIT** — copy uses 53.2% of budget |
| B4 | Bus alone does **not** block 30 fps (budget 33.33 ms) | **HIT** — copy uses 66.4%; tight, not over |
| B5 | Current product DDR contract **rejects** 1280×720 | **HIT** — see §2 |
| M1 | “ms-scale margin” is a real FEED full-stack ~1.5 ms @24 fps number, not a GDM-only artifact | **HIT** — FEED summary |
| M2 | GDM fix alone makes 2000→higher bitrate obviously safe | **MISS** — wall-clock stack was already ms-tight on isolated FEED decode path |
| M3 | Enough evidence to raise `kPlex480pWeakBitrateKbps` now | **MISS** — no bitrate sweep; leave 2000 |

---

## 1. 720p DDR/bus projection (archive instrument)

### 1.1 Anchor (quoted device lines)

624×480 I420 `len=449280`, 1800 loops:

| Mode | frame_ms | MiBps |
|------|---------:|------:|
| O_SYNC | 7.378 | 58.074 |
| **no O_SYNC** | **7.199** | **59.521** |
| no-sync + cacheflush | 13.246 | 32.348 |

Load-bearing rate for projection: **59.521 MiB/s** (no-sync row; product default is O_SYNC ≈ same class at 58.074).

### 1.2 Byte volumes and copy-only projection

| Tier | Bytes | MiB | ms @ 59.521 MiB/s | copy-only fps cap | % of 24 fps budget | % of 30 fps budget |
|------|------:|----:|------------------:|------------------:|-------------------:|-------------------:|
| 320×240 I420 | 115200 | 0.110 | 1.846 | 541.8 | 4.4% | 5.5% |
| 624×480 I420 | 449280 | 0.428 | **7.199** (measured) | 138.9 | 17.3% | 21.6% |
| 640×480 I420 | 460800 | 0.439 | 7.383 | 135.4 | 17.7% | 22.1% |
| **1280×720 I420** | **1382400** | **1.318** | **22.149** | **45.1** | **53.2%** | **66.4%** |

Frame budgets: 24 fps = **41.667 ms**; 30 fps = **33.333 ms**.

### 1.3 Plain bus verdict

| Question | Answer |
|----------|--------|
| Does the **bus** block 720p24? | **No** — projected pure fill **22.1 ms < 41.7 ms** (~19.5 ms headroom before any other work) |
| Does the **bus** block 720p30? | **No as pure fill** — 22.1 ms < 33.3 ms (~11.2 ms headroom); **comfortable? No** |
| Is the bus the decision driver? | **No.** Bus is tight-but-viable in projection; **CPU is the hard ceiling** (live 480p total **89.8 %onecpu**; linear → ~276% @720p24 vs 200% dual-A9 — parent/harness A/B, not remeasured here) |

**Caveats (not guesses — limits of evidence):**

1. Rate measured at **449280 B**, not 1.38 MB. If larger copies lose efficiency, real ms rises — **unmeasured**.
2. Product `lastPushMs` includes PLXD/prep/doorbell, not only memcpy. FEED product present mean **10.41 ms** @480p. Scaling only the copy term is safer than scaling the whole 10.41; **fixed overhead at 720p is unknown**.
3. **cacheflush** path at 32.3 MiB/s would put 720p copy at **~40.8 ms** — that path **would** consume nearly a full 24 fps budget on copy alone. Default product is O_SYNC without flush.

### 1.4 Structural product blocker (stronger than bus)

Quoted `ddr_frame_layout.hpp`:

```text
constexpr CodedWidth kDdrFrameStoreMaxWidth{640};
constexpr CodedHeight kDdrFrameStoreMaxHeight{480};
// bank stride currently 512 KiB (kPlex480pYuv420pBankStride = 0x80000)
```

`Plex.qsf`: `FRAME_W=640`, `FRAME_H=480`.

| Check | 624×480 | 1280×720 |
|-------|---------|----------|
| MB-aligned | yes | yes |
| ≤ FRAME_W/H | yes | **NO** (1280>640, 720>480) |
| `alignUp(frame_bytes, 0x40000) ≤ 0x80000` | 0x80000 OK | **0x180000 > 0x80000 FAIL** |

**`ddrFrameStoreAcceptsResolution(1280,720)` is false on current contract.**  
Even a free bus cannot deliver product DDR 720p until RTL geometry + bank map change (or a non-DDR present path is designed). HDMI-with-VGA-letterbox still needs a defined store/scanout contract — **not present for 720p coded today**.

---

## 2. Bitrate margin claim (`osd_menu.hpp:114-116`)

### 2.1 What the code says

```text
// Use the 2000 kbps PMS/validator floor until W-FEED (or equivalent
// ARM-boundary profiling) proves a higher bitrate safe; this path has
// only millisecond-scale decode margin.
kPlex480pWeakBitrateKbps = 2000
```

### 2.2 What W-FEED actually measured (quoted summary)

Sample: **624×480**, **1412 kb/s** Constrained Baseline, 1800 frames @ 25 fps content.

| Bucket | wall ms/f |
|--------|----------:|
| decode_null | 21.562 |
| +scale delta | 2.954 |
| +pipe delta | 5.263 |
| **decode+scale+pipe** | **29.780** |
| product present/DDR | 10.411 |
| **sum (classic 40.19)** | **40.190** |

| Budget | decode+pipe margin | **full-stack margin** |
|--------|-------------------:|----------------------:|
| 24 fps (41.667 ms) | +11.887 ms | **+1.476 ms** |
| 25 fps (40.000 ms) | +10.220 ms | **−0.190 ms** |
| 30 fps (33.333 ms) | +3.554 ms | **−6.857 ms** |

So “millisecond-scale margin” is **not folklore**: full ARM pipeline at **1412 kb/s** sits **~1.5 ms under a 24 fps tick** and is **already slightly over a 25 fps tick**.

### 2.3 Did GDM invalidate that?

| Fact | Implication |
|------|-------------|
| FEED `decode_null` / scale / pipe are **isolated ffmpeg_cpu_probe** processes | Those wall times are **not** explained by misterplexd GDM spin |
| GDM fix recovered ~1 full core of **system** CPU | Helps concurrent headroom; does **not** rewrite FEED’s 29.8 ms decode+pipe wall |
| Live post-GDM A/B (harness): 480p **mplex 20.8 + ffmpeg 69.0 = 89.8 %onecpu** | ~**110 %onecpu free** on dual-A9 — CPU % headroom exists |
| Wall-clock stack margin at 1412 kb/s was **1.5 ms @24** | Raising bitrate increases decode work → attacks the **same ms budget** |

**Verdict on staleness:**

- The comment’s **direction is still right**: 480p ARM path is margin-poor in **milliseconds per frame**, not flush with spare decode time.
- What is stale is any reading that “GDM burned the margin, so post-GDM we can freely raise bitrate.” **FEED already showed ms-scale full-stack margin without needing GDM as the cause.**
- **W-FEED did not prove a higher bitrate safe** — it profiled a **1412 kb/s** asset under a 2000 ceiling. The “until W-FEED proves higher” gate is **still open**.

### 2.4 Should `kPlex480pWeakBitrateKbps` change?

| Option | Evidence | Decision |
|--------|----------|----------|
| Keep **2000** | FEED full-stack +1.5 ms @24 at 1412 kb/s; no higher-BR sweep; live 480p already 89.8% onecpu | **KEEP** |
| Raise (e.g. 3000–4000) | **No** on-device bitrate A/B with drops/decode_null_ms | **Do not change** |
| Lower | No evidence current 2000 fails post-GDM | **Do not change** |

Crude **unproven** model (scale only `decode_null` linearly with bitrate; scale/pipe/present fixed) — **published as non-evidence**:

| Requested kbps | toy dsp ms | toy full-stack @24 |
|---------------:|-----------:|-------------------:|
| 1412 (measured class) | 29.8 | +1.5 ms |
| 2000 | ~38.8 | **negative** |
| 3000 | ~54 | hard fail |

That toy model is **not** a finding (bitrate≠linear CPU). It only shows why **raising without a sweep is reckless**.

**Product recommendation (report only, no code change):**  
Keep **2000**. Next proof is a **bitrate ladder A/B** on the harness (same clip, 2000/3000/4000) scoring: `ffmpeg_pct_onecpu`, `drops_delta`, `vfps/pfps`, `ddr_copy_us_p`, and if possible isolated `decode_null_ms_f`. Until that is green, higher bitrate is **unknown**, not “unlocked by GDM.”

Shipping default **240p @ 1000** unchanged.

---

## 3. Device handoff (still `w-device`)

Do **not** run on daily-driver without their window. Recipe remains:

```bash
# DDR fill both tiers + optional 720p len (expect accept fail or map fail today)
WIDTH=320 HEIGHT=240 LOOPS=1000 ./scripts/run_c2_ddr_bench.sh
WIDTH=624 HEIGHT=480 GEOMETRY=plex480p LOOPS=1000 ./scripts/run_c2_ddr_bench.sh
# len-only probe (layout bypass) — measures bus at 720p bytes if /dev/mem allows
# ddr_write_bench --len 1382400 --loops 500 --sync / --no-sync

# Bitrate margin (product)
# same PLEX_KEY, WINDOW_S=60, tiers 480p; conf WEAK_BITRATE=2000 then 3000 (lab only)
PLEX_KEY=... TIER=480p ./tests/hw/test_p480_ab_harness.sh
```

Capture: `ddr_copy_us_p`, `ddr_total_us_p`, `ddr_plxd_used_x100_p`, process+thread CPU JSON, `drops_delta`, `decode=` line, SOURCE_SHA, RBF md5.

---

## 4. Bottom line

| Topic | One-line |
|-------|----------|
| 720p **bus** @24 | **Not the blocker** (~22 ms copy / 41.7 ms) |
| 720p **bus** @30 | **Not over budget as pure fill**; little spare |
| 720p **product today** | **Blocked by FRAME_W/H=640×480 and 512 KiB bank** before bus |
| 720p **CPU** | Parent/harness: ~276% projected — **binds first** |
| 2000 kbps floor | **Keep** — FEED ms-scale full-stack margin at 1412 kb/s still stands; GDM fix ≠ bitrate unlock |
