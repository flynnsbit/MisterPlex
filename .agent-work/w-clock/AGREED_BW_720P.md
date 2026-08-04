# AGREED single number — 720p24 fabric (w-clock ⊕ w-mem ⊕ w-scaler)

**Status:** proposed by w-clock for three-lane lock.  
**Product clock (settled):** MULTI + **PPC=2** + **clk_pix@29.70**, **clk_sys@20** (STA stub-in Fmax 23.17; @24 FAIL).  
**Format:** I420 / YUV420p coded **1280×720** (`kPlex720pYuv420pBytes` / `DDR_FRAME_720P_YUV420P_BYTES`).

---

## THE ONE NUMBER

| Symbol | Value | Meaning |
|--------|------:|---------|
| **B_frame** | **1_382_400 B** | 1280×720×3/2 I420 |
| **R_fps** | **24** | content / present target |
| **BW_frame** | **B_frame × R_fps = 33_177_600 B/s = 33.1776 MB/s (SI 10⁶)** | **one direction, one full frame/s** |
| **BW_steady_RW** | **2 × BW_frame = 66.3552 MB/s** | ARM write + fabric read, steady state, no thrash |
| **DDR peak model** | **clk_ddr 90 MHz × 8 B = 720 MB/s** | fabric-side peak |
| **BW_frame / peak** | **4.608%** | write alone |
| **BW_steady_RW / peak** | **9.216%** | R+W steady |

### **Agreed headline (quote this):**

> **33.18 MB/s per full-frame direction @24 fps I420 1280×720**  
> **(exact 33.1776 = 1_382_400 × 24 / 1e6). Steady R+W = 66.36 MB/s.**

Do **not** report 33.18 as “total DDR load” without saying R+W doubles it.  
Do **not** use MiB/s (1024) in the same sentence without labeling — 31.64 MiB/s is the same bytes, different unit.

---

## Source of each term

| Term | Source |
|------|--------|
| 1280×720×1.5 | `host/libmisterplex/ddr_frame_layout.hpp` `kPlex720pYuv420pBytes = 1382400`; `ddr_frame_layout_params.svh` `DDR_FRAME_720P_YUV420P_BYTES` |
| ×24 fps | product content rate (PMS 24/1; CEA pack @24) |
| MB/s = /1e6 | SI; matches w-mem log `push_MBps 24=33.178` |
| clk_ddr 90 / 8 B | `pll_0002.v` out2 `90.000000 MHz`; Avalon-ish 64-bit beat model used by w-mem meter |
| Peak 720 MB/s | 90e6×8; w-mem `safe_budget_25pct=180.0` |
| PPC=2 | **does not** multiply BW_frame. N pixels/clk come from **linebuf qwords already fetched**. DDR average stays 1 frame read / present. |
| clk_pix 29.70 | glass CE rate (1650×750×24); **not** a second I420 stream. YUV→RGB is fabric; DDR still I420 @ frame rate. |
| 16-line floor | blackout **latency** (500 µs class), not average BW. w-mem: `1280x720@30 line_count=16 OK under 500us`; 8 lines underruns. w-clock ABI floors LINE_COUNT→16 on FRAME 1280×720. |

---

## What PPC=2 *does* change (not the 33.18)

| Quantity | Value | Lane |
|----------|------:|------|
| Fabric peak unique Mpix/s @ sys | F_sys×PPC = 20e6×2 = **40.0** | w-clock |
| CEA need | **29.70** Mpix/s | w-clock |
| RGB into CDC FIFO | PPC×3 B/sysclk = **6 B/clk** @ fire | w-clock |
| Glass unpack | 1 RGB/clk_pix @ 29.70 | w-clock |
| Content window map | identity 1280→1280 or scale into glass | w-scaler |
| Bank/doorbell/stride | `0x30180000` / `0x3047F000` / `0x180000` | w-mem + w-clock ABI |

---

## w-mem sim alignment (not a second number)

w-mem G2/G4: **345_600 beats / (90e6/24) cycles** with host+scan = one write frame + one read frame of beats:

```
345600 beats × 8 B = 2_764_800 B = 2 × 1_382_400  →  exactly 2 × B_frame
```

That is **BW_steady_RW** in one frame time — same arithmetic, beat-counted.  
Ideal `beat_fire` counter ≠ real bus (w-mem labels NOT bus proof); real-store stall TB is separate.

Host `/dev/mem` copy ~**88 MiB/s** (w-mem log) >> 33.18 MB/s push — ARM memcpy headroom is not the fabric beat budget.

---

## Explicit non-claims

1. **33.18 MB/s is not “720p works”.** Decode-only 1.3× still excludes this write + present.  
2. **PPC=2 does not require 66 MB/s write.** Write stays one frame/s unless double-buffer thrash.  
3. **Glass 29.7 Mpix/s × 1.5 ≠ DDR read** for budgeting averages — use **frame rate × B_frame**.  
4. **clk_sys@24 is OFF the table** on stub-in STA (23.17); nostub may reopen — new STA only.

---

## Three-lane lock line (paste into status)

```
AGREED_BW: 33.1776 MB/s per direction @24 I420 1280x720 (B=1382400);
steady R+W 66.3552 MB/s (9.2% of 720 MB/s peak@90MHz×8);
PPC2 does not scale DDR average; 16-line is latency not BW.
```


## Addendum — reply to w-scaler B/clk framing

### Headline (unchanged)
**33.1776 MB/s per full-frame direction** (not a DE-peak B/clk).

### Optional B/clk form (same bytes, clk_sys@20 domain)
`BW_frame / F_sys = 33.1776e6 / 20e6 = **1.65888 B/clk_sys average** per direction.`

### Corrections to scaler draft
1. **PPC=2 ≠ 3.0 B/clk DDR during DE.** Present RGB comes from **line-buffer qwords**
   (`ddr_frame_store.sv` hit path / `rd_miss_now`); DDRAM beats are **line fills**,
   averaged to one I420 frame/present ≈ 33.1776 MB/s, not 2×1.5 per sysclk.
2. **~93 MB/s (33+60) is not the design load.** 60 MB/s would be 40 Mpix/s×1.5 if every
   fabric pixel were a unique DDR I420 fetch — false under linebuf. Steady design load
   remains **~66.36 MB/s R+W**.
3. **Write vs present-read ports:** ARM write = HPS `/dev/mem` into bank phys
   (`kPlex720pPhysBase`); fabric read = `DDRAM_*` in `ddr_frame_store`. Same DRAM die,
   **two masters** — concurrent in wall-clock; not the same B/clk counter domain.
   docs/display-resolution.md: ARM-write column is simultaneous HPS DDR fabric traffic.
