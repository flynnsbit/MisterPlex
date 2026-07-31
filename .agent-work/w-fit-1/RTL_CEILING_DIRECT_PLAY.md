# RTL ceiling analysis — fabric H.264 direct play on DE10-Nano

**Lane:** w-fit · **2026-07-31** · **analysis only · NO FIT · NO DEVICE**  
**Shipping product:** RBF `c5382bee` + ARM daemon (DDR present works; decode is ARM).  
**Motivation allowed:** **direct play** (kill PMS transcode / play original Parts).  
**Motivation forbidden:** ARM CPU relief (parent ERROR 15 — retracted).  
**Scale-vs-decode ARM split:** **UNRESOLVED** between thread-class (~5.8 decode / ~50 scale) and component isolation (decode_null 21.6 ms vs +scale 3.0 ms). **Neither instrument justifies fabric decode for CPU.** Do not combine them causally.

Every number is tagged **`measured`**, **`derived`**, or **`assumed`**.

---

## 0. Plain answer (read this first)

| Tier | Reachable on this device? |
|------|---------------------------|
| **A. Full-library direct play** (High + CABAC + B-frames + typical 720p/1080p H.264, let alone HEVC) | **NO — not reachable.** Physics + missing engines + RAM. |
| **B. Narrow CB/CAVLC ≤480p@≤25 original Parts** (lab-shelf profile) | **Not proven; unlikely soon.** 20 MHz + measured cy/MB already fail 480p by **~4.3×**; inter still product-red. |
| **C. Narrow CB/CAVLC ≤240p@≤25 original Parts only** | **Possibly someday** after product-green inter + ≤~2667 cy/MB full path — multi-quarter, still tiny user cohort on a real library. |
| **D. Ship path (today)** ARM FFmpeg decode + FPGA DDR present + PMS Baseline **transcode** | **Already works** at 240p and native 480p on silicon (`c5382bee`). |

**Roadmap recommendation:** treat fabric decode as a **research ceiling**, not a near-term product program. Prefer server/ARM quality ladder and conf wins. **An exclusive Quartus fit is not justified by direct-play today.**

---

## 1. Device envelope (what we actually have)

### 1.1 Fit resources — shipping-class baseline

| Resource | Value | Tag | Source |
|----------|------:|-----|--------|
| ALM used | **21,095 / 41,910** | measured | Parent fit baseline (also cited for `c5382bee` class; probe-excluded product) |
| ALM free | **~20,815** | derived | 41910−21095 |
| DSP used | **74 / 112** | measured | Same baseline |
| DSP free | **38** | derived | 112−74 |
| DSP “product margin” | **~1 above product with probe excluded** | measured (parent) | Parent re-scope: do not treat 38 as all spendable on decode farm without re-map |
| RAM (M10K blocks) | **465 / 553** | measured | Same |
| M10K free | **88 physical blocks** | derived | 553−465; prior “~46% free” **retracted** (wrong unit) |
| setup slack | **+0.165 ns** | measured | Parent |
| hold slack | **+0.245 ns** | measured | Parent |
| Working core md5 | **c5382bee** | measured | Parent silicon |

### 1.2 Decode clock (do not use 50 MHz)

| Clock | Freq | Tag | Source |
|-------|-----:|-----|--------|
| `clk_sys` (decode / stream_path) | **20.000 MHz** | measured | `pll_0002.v` `.output_clock_frequency0("20.000000 MHz")` → `Plex.sv` `outclk_0(clk_sys)` |
| Board osc `FPGA_CLK*_50` | 50 MHz | measured | `sys_top.sdc` — **ref only, not decode** |
| DDR bridge domain | ~90 MHz class | measured (docs) | Present path; not MB paint budget |

Any budget written at 50 MHz (e.g. historical “~2000 cy/MB @ 50 MHz”) is **invalid** for decode throughput (`docs/throughput-budget-vs-4037.md`).

### 1.3 Throughput budgets (arithmetic)

```
cy/MB_budget = f_clk / (MB_per_frame × fps)
MB_per_frame = (W/16)×(H/16)
```

| Geometry | MB/frame | fps | Budget cy/MB | Tag |
|----------|---------:|----:|-------------:|-----|
| 320×240 | 300 | 25 | **2,666.7** | derived |
| 320×240 | 300 | 23.976 | **~2,780.6** | derived |
| 320×240 | 300 | 30 | **2,222.2** | derived |
| 624×480 | 1170 | 25 | **683.8** | derived |
| 624×480 | 1170 | 30 | **570.0** | derived |
| 1280×720 | 3600 | 25 | **222.2** | derived |
| 1920×1080 | 8160 | 25 | **98.0** | derived |

Parent’s stated product stress budgets match: **2,667 @ 320×240@25** and **684 @ 624×480@25** (derived; same formula).

### 1.4 Measured paint / path cost

| Figure | Value | Tag | Notes |
|--------|------:|-----|-------|
| paint_per_mb frame0 @788aa5f (320) | **4,036.9** | measured | `docs/evidence/plane_m10k_clip1_788aa5f.log` |
| paint_per_mb frame0 @788aa5f (624) | **3,977.9** | measured | clip2 log |
| After RMW pipelining | **2,965.8 cy/MB** | measured (parent) | Parent re-scope; stage split not re-logged this lane — treat as authority until republished |
| vs 2667 (240p@25) | **2,965.8 / 2,667 ≈ 1.11× over** | derived | Close but **still FAIL** realtime I-paint class |
| vs 684 (480p@25) | **2,965.8 / 684 ≈ 4.34× over** | derived | **Hard fail** |
| vs 222 (720p@25) | **~13× over** | derived | Kill |
| vs 98 (1080p@25) | **~30× over** | derived | Kill |

**Caveat (rule 0):** paint_per_mb is **I-recon / paint window**, not full product P + deblock + DDR WB + present arb average (`throughput-budget-vs-4037.md` §5). Full path can only be **worse or equal**, not magically under 684. Check that would settle full-path: instrument `summary.cycles` / stage counters on tip with product wiring.

---

## 2. What “direct play” demands vs what fabric has

### 2.1 Product contract today (by design: **transcode**, not DP)

| Item | Contract | Tag |
|------|----------|-----|
| PMS profile | Baseline `profile_idc=66`, CAVLC, refs=1, no B, ≤624×480 ladder | measured docs/`MiSTerPlex.xml` |
| DirectPlayProfiles | **Empty on purpose** | measured XML comment |
| Pixels user sees | **ARM decode → DDR present** | measured silicon parent |
| Fabric `CAP_INTER_*` | **0** → HOST_INTER | measured `h264_hybrid_mb_own.sv` |
| Fabric `CAP_CABAC` | **0** → HOST_CABAC / skip | measured; **no cabac engine RTL** |
| Silent PMS fallback without profile | High `profile_idc=100`, cabac=1, B, refs=4 | measured `docs/pms-baseline-profile.md` |

### 2.2 Lab PMS shelf (only library on 192.168.1.24)

All 7 “MiSTerPlex Tests” items: **Baseline + CAVLC + zero B** (measured annex-B probe).  
**Other Videos = 0 items.** No real-user High/CABAC census possible here.  
**0/7** match strict 480p gate (geo/refs). Closest DP-like Part: RK6 624×480 CB.

Industry / fallback High+CABAC is **assumed** for “typical Plex library” until a real section is probed (n≥50).

### 2.3 Feature → resource class

| Need for real DP | Fabric status | Area class | Thruput class | Tag |
|------------------|---------------|------------|---------------|-----|
| CAVLC + IQ/IDCT | Present (CB path) | mostly spent | in 2965 figure | measured |
| Intra | Partial / hybrid | med ALM | med | measured caps |
| **Inter P + MC + DPB** | **CAP_INTER=0** | large ALM + DDR BW | **dominant** cy | measured red |
| Deblock | Exists, not product-wired | ~1k ALM class (map note) | +cy | measured map order |
| **CABAC** | **Absent** | very large ALM + **M10K contexts** | serial bit risk | measured absent |
| B / list1 / reorder | Absent | DPB×N DDR + ctrl | latency/BW | measured |
| refs>1 | Contract forces 1; shelf often 3 | DPB slots | BW | measured |
| 720p/1080p | Not in ship ladder | DDR frames OK | **cy/MB kill @20 MHz** | derived |
| w-area −32 DSP dequant | Gate-green bit-exact, **unfitted** | **−32 DSP** if map shows it | does **not** create CABAC or 4× thruput | measured gates / unmeasured fit |

---

## 3. Tier arithmetic — what fits the ceiling

### Tier A — Full library DP (High/CABAC/B/HD)

**Verdict: NOT REACHABLE.**

| Kill | Arithmetic / fact | Tag |
|------|-------------------|-----|
| Entropy | No CABAC engine; High default is cabac=1 | measured |
| Tools | B + multi-ref + High tools absent | measured |
| 720p@25 | need ≤222 cy/MB; have ~2966 paint class → **~13×** | derived |
| 1080p@25 | need ≤98 cy/MB → **~30×** | derived |
| RAM | 88 M10K free for CABAC contexts + linebufs + FIFOs + MC — **assumed insufficient** for full CABAC+inter farm without measured map; order-of-magnitude industry CABAC engines eat well beyond 88 blocks when naive | assumed + measured free pool |
| Clock raise to close HD gap | 2966→222 needs **~13×** clock → **~260 MHz** decode — not a Cyclone V / current STA story at +0.165 setup | derived + measured slack |
| Parallel MB farms | N-wide issue to cut cy/MB by 4–13× → ALMs and M10K scale ~N | assumed architecture |

**Give up nothing useful:** even giving up ascal quality, OSD, SPI legacy, dequant DSP, etc. does not buy a CABAC+HD engine inside 88 M10K and 20 MHz.

### Tier B — Original CB/CAVLC ≤480p@25 (no B, refs=1)

**Verdict: NOT PROVEN; treat as NOT NEAR-TERM REACHABLE until thruput closes.**

| Gate | Need | Have | Tag |
|------|------|------|-----|
| Entropy | CAVLC | yes | measured |
| Inter realtime | product-green P | **CAP_INTER=0** | measured |
| cy/MB | ≤**684** | **~2,966** paint → **4.34× slow** | derived |
| Close gap by clock only | 20×4.34 ≈ **87 MHz** `clk_sys` | STA baseline +0.165; **assumed HARD** without redesign | derived + measured |
| Close gap by parallel only | ~4–5× MB parallelism | competes for **ALM + 88 M10K**; present path already 21k ALM | assumed |
| Area left | ~21k ALM free looks large | RAM+timing+thruput bind first | measured free ALM |

**What would have to be true (all):**

1. Full path ≤684 cy/MB median at 624×480@25 @20 MHz **or** proven higher decode clock with non-negative setup on product netlist.  
2. `CAP_INTER_*` product-green, bit-exact P, not HOST_INTER.  
3. Product accepts “DP only for CB≤480p refs=1 no-B” UX (tiny real-library fraction — **assumed** until census).  
4. Map shows CABAC still off; no HD scope creep.

**What would be given up / spent:**

- Most remaining **timing margin** if clock raised.  
- Large fraction of **free ALM** and likely **most of 88 M10K** for MC/linebufs/FIFOs (assumed).  
- Engineering quarters that do **not** help High-library users.  
- Risk of regressing shipping `c5382bee` present path (do-not-ship history).

**−32 DSP dequant:** frees DSP headroom (**assumed −32 on fit** if map matches w-area claim); **does not** move 2966→684.

### Tier C — Original CB/CAVLC ≤240p@25 only

**Verdict: CEILING CANDIDATE ONLY — still blocked on inter + ~11% thruput.**

| Gate | Need | Have | Tag |
|------|------|------|-----|
| cy/MB | ≤**2,667** | **2,965.8** → **1.11×** | derived |
| Inter | product-green | red | measured |
| Cohort size | material library % | **unknown** without real section | assumed small |

Closing 1.11× is **plausible** with further paint/RMW/overlap work **in simulation** (no fit required to measure). Inter green is the larger product gate. Even then, user-visible DP value is **only** for already-Baseline 240p originals — ARM already decodes those; fabric wins only if ARM cannot sustain bitrate (rare at 240p).

### Tier D — Status quo (ship)

**Verdict: CORRECT PRODUCT CEILING FOR NOW.**

ARM already **is** the direct-play decoder for anything FFmpeg can open; PMS profile **forces transcode** into CB for the weak client story. Fabric’s unique DP value appears only when **ARM cannot sustain the original Part** (high bitrate/resolution) — which is exactly the tier A/B physics wall.

---

## 4. Cost to “buy” headroom (order of magnitude)

| Lever | Expected effect on cy/MB | Area / risk | Tag |
|-------|--------------------------|-------------|-----|
| w-area comb dequant (−32 DSP) | ~0 on serial paint bottleneck | −32 DSP, small ALM; unfitted | assumed / gates green |
| More RMW / paint overlap | maybe 10–30% (guess) | ALM; must stay bit-exact | assumed |
| Raise `clk_sys` 20→40 MHz | **2×** budget (2667→5333, 684→1368) | STA; may HARD_FAIL like historical fits | derived budget · assumed risk |
| Raise 20→87 MHz | **~4.3×** — closes 480p paint gap alone | **assumed unachievable** on current +0.165 design | derived |
| N=4 MB parallel | ~4× if perfect | ~4× hot ALM/RAM; wiring hell | assumed |
| Drop 480p fabric DP goal | removes 684 gate | product scope | decision |
| Drop fabric DP entirely | N/A | keep ALM for present/OSD/identity | decision |

**Honest packing:** free ALMs (~21k) are **not** the scarce resource. **88 M10K + 20 MHz + thin setup** are. Spending ALMs without a thruput theory that hits 684 is how exclusive fits get burned.

---

## 5. Falsifiers (before any multi-month fabric DP program)

### Kill (any one)

| ID | Criterion | Tag when measured |
|----|-----------|-------------------|
| K1 | Real library n≥50: &lt;20% H.264 CB/CAVLC/no-B/≤480p | measured census |
| K2 | Real library &gt;50% HEVC/AV1/VP9 | measured |
| K3 | Full product path cannot show ≤684 cy/MB @624×480@25@20 MHz after one focused thruput effort | measured counters |
| K4 | CABAC map estimate &gt;88 M10K or setup negative | measured map (needs grant) |
| K5 | Goal restated as HD High/CABAC original | instant kill by §1.3 |

### Pursue Tier C only if all

| ID | Criterion |
|----|-----------|
| P1 | Census shows material CB≤240p cohort **or** explicit niche UX |
| P2 | Inter product-green bit-exact |
| P3 | Full path ≤2667 cy/MB @240p@25 |
| P4 | Server-transcode pain still user-visible after ARM path excellent |
| P5 | Written non-goal: no HD High/CABAC/B in this program |

**Zero-fit next measurements:** real library probe JSON; publish stage split for 2965.8; keep PLXC fail-closed until identity RBF.

---

## 6. Integration branch held for a *future* fit (not requested)

**Branch:** `w-fit-integ-c5382bee-dequant-swap`  
**Code tip (ledger):** `825d205d` · **docs tip:** see status  
**Contents (shelved free-riders, not DP unlocks):**

| Item | Role | DP impact |
|------|------|-----------|
| PLXC @ doorbell+0x130 | running-core identity | test infra |
| `907e5950` swap_pending hold | latent NBA race | present robustness |
| comb shift-add dequant | −32 DSP bit-exact unfitted | DSP headroom only |
| P5 file frame ledger + P6 docs | soak integrity | ARM |
| video_regression dual pairs + geom map | promote gates | host |

### Bundle pre-registration vs baseline ALM 21,095 · DSP 74 · RAM 465 · setup +0.165 · hold +0.245

| Metric | Predict after PLXC + 907e + dequant | Tag |
|--------|-------------------------------------|-----|
| ALM | **21,120 … 21,250** (+25…+155) | assumed (const PLXC + small hold logic) |
| DSP | **42** (**−32** hard expect) | assumed from w-area; **miss if fit ≠ −32 is a finding** |
| RAM | **465** (0) | assumed |
| setup | **+0.10 … +0.165** | assumed; low risk const DIN |
| hold | **≥ +0.20** | assumed |

**V_STORE=480** (separate, not on bundle): ALM +55…+300, DSP 0, RAM +0…+5 — still needs 480-line timing; **not** a DP unlock (`.agent-work/w-fit-1/V_STORE_480_IMPACT.md`).

**Fit bar (parent, accepted):** sim RED on current RTL + GREEN on fix with **TB execution proven**; `PINNOTFOUND`/`%Error` → rc=2. **No slot requested.**

---

## 7. Bottom line

1. **Direct play is the only honest fabric-decode why** left after ERROR 15.  
2. **Full-library DP is not reachable** on Cyclone V @ **20 MHz** with **88 M10K free** and no CABAC engine.  
3. **Even CB 480p fabric DP fails the thruput test today by ~4.3×** against parent’s **2,965.8 cy/MB** vs **684** budget.  
4. **240p CB fabric DP** is the only non-fantasy tier and is still **inter-red** and **~11% over** paint budget — and may not beat ARM for user value.  
5. **Do not spend exclusive fits on fabric decode** until K/P gates move with measured counters and a real library census.  
6. **Ship and invest in:** ARM+DDR present (`c5382bee`), promote/soak integrity (P5/P6), conf quality, server ladder — not CABAC-in-FPGA.

**One sentence:** *The RTL ceiling for direct play on this board is “maybe tiny CB 240p after thruput+inter,” not “replace PMS transcode for a real library”; HD/High/CABAC direct play is a physics no.*
