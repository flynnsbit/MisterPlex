# 720p60 stretch — 4 px/clk feasibility (w-clock)

Clean parent budget (post-retraction): ARM decode alone **35.94 ms/f** @24.
At **60 fps** deadline = **16.667 ms/f** ≪ 35.94 → **ARM cannot decode 720p60**.
60 is fabric-decode + fabric-present only.

## 1) Rate table (exact)

CEA-861 720p: H_TOTAL=1650, V_TOTAL=750, active 1280×720.

| Quantity | Formula | Hz / MHz |
|----------|---------|----------|
| Content 720p60 | 1280×720×60 | **55.296 Mpix/s** |
| CEA 720p60 | 1650×750×60 | **74.250 Mpix/s** |
| Fabric clk @1ppc CEA | 74.250 | **WALL** vs Fmax 32 |
| Fabric clk @2ppc CEA | 37.125 | **FAIL** nostub 32.04/32.59 |
| Fabric clk @4ppc CEA | **18.5625** | **OK vs ship 20** (paper) |
| Fabric clk @4ppc content | 13.824 | OK |
| Output CE=1 need for true 60 | **74.25 MHz clk_pix** | PLL — not shipping |

**Parent’s 18.56 MHz @4ppc: CONFIRMED** (74.25/4).

## 2) Same-clock honesty (again)

Shipping `clk_sys=20`, `CE_PIXEL=1` → output ≤ **20 Mpix/s** ≈ 16.2 Hz at CEA totals.
**4ppc does not create 60 Hz HDMI by itself.** It makes fabric *work* fit under 20 MHz
while a **faster `clk_pix`** (or external ascal policy) drains 1 px/clk at 74.25.

Integration milestone (moving 1280×720) can ship at reduced refresh; **product 720p60**
needs `CLK_PIX_PLL_PLAN` stage for 74.25 (or measured ascal path — parent device).

## 3) M10K cost (4ppc vs 2ppc)

| Resource | 2ppc | 4ppc | Notes |
|----------|------|------|-------|
| Y/U/V line BRAMs | sized by **CODED_W**, not PPC | **same** | 1280 → 160 Y qwords ≈ 1 M10K/line @64b (scaler claim) |
| Port B dual-read | same physical M10K | **same** | no extra M10K |
| `present_npx_path` FIFO | MLAB 24b×depth | **same order** | AW=6 default |
| `yuv_bt601_npx` | 2× BT.601 | **4× BT.601** | **ALMs / Fmax**, not M10K |
| Beam | +2 step | +4 step + short 1650%4=2 | tiny ALM |

Parent nostub free M10K: **356** (was 88). Going 640→1280 line width roughly
**doubles** bits per line buffer instance; double-buffer LINE_COUNT=8 class stays
comfortably inside 356 if product already holds ~200 M10K used.  
**Exact post-fit M10K delta: unknown until integration map.rpt.**

**Verdict:** 4ppc is **not M10K-bound**. It is **Fmax/ALM-bound** on parallel YUV.

## 4) DDR read bandwidth (scan-out fill)

YUV420 1280×720 frame = 1280×720×1.5 = **1 382 400 B**.

| Mode | MB/s sustained read | vs clk_ddr peak 90×8=720 MB/s |
|------|--------------------:|------------------------------:|
| 720p24 | **33.18** | 4.6% |
| 720p60 | **82.94** | 11.5% |

Fill is line-buffered (not full-frame every pixel cycle). Scheduler must keep
want_y lines hot under 60 Hz beam. Peak headroom looks ample on paper; **arbiter
contention with fabric decode writer is unmeasured** (parent Route A lesson: measure).

At 4ppc, beam issues fewer `rd_x` groups/line (320 vs 640 @2ppc) — **helps** BRAM
port pressure; DDR fill rate still tracks **frame rate × frame bytes**, not PPC.

## 5) Feasibility ladder

| Step | What | Blocks 60? |
|------|------|------------|
| S0 | PPC=2, same-clock, 1280 DE, ~16 Hz | Yes — not 60 Hz |
| S1 | PPC=4, same-clock, prove Fmax≥20 on wider YUV | Still not 60 Hz out |
| S2 | `clk_pix`=74.25, PPC=4, FIFO CDC, STA gray+false_path | **Candidate real 60** |
| S3 | Fabric decode produces 720p60 banks | ARM out of decode |

## 6) What this lane lands now vs later

**Now (no fit):** arithmetic + SDC/CDC contract + PPC=4 beam/DE tests + H ownership.
**Not now:** PLL 74.25 apply, claim STA close, claim 60 Hz on glass.
