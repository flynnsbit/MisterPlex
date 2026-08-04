# 720p present clock plan — w-clock

**Branch:** `w-clock-720p-plan`  
**Base main:** `956e05d7` (pin at branch create)  
**Architecture (settled):** ARM decodes 720p → DDR I420 → fabric YUV→RGB + beam → ascal → HDMI.

## PRE-REGISTER Fmax (before packaging digests)

| Scenario | Predicted Fmax Slow 1100mV 100C | Owner (if known) | @ required |
|----------|----------------------------------|------------------|------------|
| clk_sys product 20 MHz, stub-class | 22.5–23.5 MHz | not named in plain STA export | PASS slack@20 |
| clk_sys @24 MHz retune, stub-class | same ~23.2 | same | **FAIL** 23.2&lt;24 |
| clk_sys nostub-class | 30–35 MHz | residual_csum if present | PASS@20; PASS@24 possible |
| clk_pix 29.70 new (MULTI unpack) | ≥40 MHz predicted | present_npx_path unpack | PASS@29.70 if light |
| clk_ddr 90 | ~90–96 MHz prior | DDR bridge | PASS@90 |

### POST-MEASURE delta (retained report)

Source: `fpga/Plex_MiSTer/output_files/Plex.sta.rpt` via `scripts/check_quartus_timing.py`:

| Clock | Restricted Fmax | Setup slack | vs PRE-REG |
|-------|-----------------|-------------|------------|
| emu\|pll general[0] **clk_sys** | **23.17 MHz** | **+0.849 ns** | HIT (22.5–23.5) |
| emu\|pll general[2] **clk_ddr** | **93.62 MHz** | +0.429 | HIT band |
| clk_pix | **absent** (macro OFF) | n/a | n/a |

**Arithmetic implication:** clk_sys@24 on this netlist class → **FAIL** (23.17 &lt; 24). Gate confirms: `--min-fmax-mhz 24` → rc=1.

Historical nostub **32.59 MHz** (fit-nostub-chrome class, Memory/parent verdict) is a different netlist — not this report. Do not use as product proof without a new fit.

## 1. Pixel clock arithmetic (CEA vs compact)

### Product path on this tip: PRESENT_MULTI_PIXEL CEA-861 720p

From `present_beam_ppc` params in `present_core.sv` and `present_video_timing_720p.sv`:

- H_TOTAL = **1650**, V_TOTAL = **750**, H_DE=1280, V_ACTIVE=720  
- PIX_PER_FRAME = 1650 × 750 = **1_237_500**

| Frame rate | Pixel clock | Arithmetic |
|------------|-------------|------------|
| 24 Hz | **29.700000 MHz** | 1_237_500 × 24 = 29_700_000 |
| 60 Hz | **74.250000 MHz** | 1_237_500 × 60 = 74_250_000 |

Active-only lower bound (no blanking): 1280×720×24 = **22.1184 Mpix/s** — necessary but not sufficient.

### Compact L4 1312×762 (NOT on main tip `956e05d7`)

If re-landed: 1312×762×24 = **23_993_856 ≈ 23.994 MHz**. That path would favor clk_sys@24 single domain. **Absent on this tip** — do not plan product around it until RTL returns.

## 2. Current PLL (quoted)

`fpga/Plex_MiSTer/rtl/pll/pll_0002.v` (SoT; ignore stale megawizard XML in comments of wrapper):

| out | Role | Frequency string |
|-----|------|------------------|
| 0 | clk_sys | `"20.000000 MHz"` |
| 1 | clk_sdram | macro (default `"100.000000 MHz"` unless SDRAM_CLK_*) |
| 2 | clk_ddr | `"90.000000 MHz"` |
| 3 | clk_pix | **only if** `PRESENT_CLK_PIX_PLL`: `"29.700000 MHz"` or `"74.250000 MHz"` |

Product default: **number_of_clocks(3)** — no out3.

## 3. Decision: clk_sys@24 vs clk_pix@29.70

### Arm A — retune clk_sys → 24 MHz, single domain

| Pro | Con |
|-----|-----|
| No new CDC | **Does not meet CEA 29.70** (24 &lt; 29.7) |
| Simple | Needs compact raster (L4) **not on tip** |
| | Stub Fmax **23.17 &lt; 24** → predicted STA **FAIL** |
| | Touches every 20 MHz consumer (inventory) |

**Verdict A: LOSE on this tip.** Only revisit if L4 compact raster returns **and** nostub-class Fmax ≥24 with margin.

### Arm B — finish separate clk_pix @ 29.70 + MULTI + CDC (RECOMMENDED)

| Pro | Con |
|-----|-----|
| Exact CEA 720p24 pixel rate | New clock domain + SDC |
| clk_sys stays 20 (STA known PASS) | CLK_VIDEO must track clk_pix (landed default-OFF) |
| CDC already in `present_npx_path` async_fifo gray+2FF | **Throughput wall:** F_sys×PPC ≥ 29.7 → need PPC≥2 @20 **or** higher F_sys |
| | PPC=2 **unblocked** on this branch: ddr_frame_store.rd_*_n + present_core glass→store |

**Verdict B: WIN for clock domain / glass rate.** Unlock still needs **N-wide RGB store + PPC=2** (or move unique-pixel beam to clk_pix). Clocking alone does not close unique 24 fps content feed at PPC=1@20.

### Throughput wall (honest)

```
Peak Mpix/s production ≈ F_sys × PPC
Need ≥ 29.70 for steady CEA 24 fps (incl blanking clocks at 1 px/clk_pix)

PPC=1 @ 20 MHz → 20.0  < 29.7  → long-term fps ≤ 20e6/1_237_500 ≈ 16.16 Hz
PPC=2 @ 20 MHz → 40.0  ≥ 29.7  → rate OK **if** lanes are unique pixels
PPC=1 @ 30 MHz → 30.0  ≥ 29.7  → rate OK; STA Fmax need ≥30 (nostub-class only historically)
```

Today MULTI path: `mp_npx_r = {PRESENT_PPC{fr}}` (`present_core.sv`) — PPC&gt;1 duplicates one sample. **Comment “40 @20/PPC2” is rate-true, content-false until store is N-wide.**

## 4. DDR read bandwidth (I420 1280×720)

Frame bytes = 1280×720×1.5 = **1_382_400** B

| fps | MB/s |
|-----|------|
| 24 | 33.1776 |
| 60 | 82.944 |

FPGA model peak at clk_ddr 90 MHz × 8 B = 720 MB/s; 25% budget = 180 MB/s → **33.18 FIT** under that model. HPS concurrent use is parent/device-measured separately — fabric read model alone does not prove host DDR headroom.

## 5. CDC discipline (clk_pix ON)

| Crossing | Protection | SDC |
|----------|------------|-----|
| sys → pix pixel groups | `present_npx_path` `async_fifo` gray pointers | `set_clock_groups -asynchronous` sys↔pix |
| sys → pix prefill_go | 2FF in npx path | covered by async groups |
| ddr ↔ pix | no intentional data path | async groups ddr↔pix |
| CLK_VIDEO / CE_PIXEL / VGA_* | same domain as unpack (`clk_pix`) when flag ON | must not leave CLK_VIDEO=clk_sys |

File: `fpga/Plex_MiSTer/Plex_clk_pix.sdc` (sourced only when QSF enables — default OFF).

## 6. Hardcoded 20 MHz consumer inventory

| Site | file:line (approx) | Role | If clk_sys→24 |
|------|-------------------|------|---------------|
| PLL out0 | `pll_0002.v` freq0 | **defines** 20 | change string |
| keep 720 pack | `present_core.sv` CLK_PIX_HZ 20e6 | fps_eff math | use 29.7 under pix PLL |
| keep 960 pack | `present_core.sv` 20e6 | 960 timing pack | scale if beam uses it |
| MP_CLK_PIX_HZ else | `present_core.sv` | MULTI without pix PLL | 24 if sys retune |
| F_SYS_HZ default | `present_pix_rate_match.sv:15` | Bresenham thresh | →24_000_000 |
| timing 720p default | `present_video_timing_720p.sv:23` | param default | document only |
| timing 960 default | `present_video_timing_960.sv:15` | param default | document only |
| H=1182 @20 comment | `present_vtotal_bresenham.sv:3,39` | V total den | recompute dens |
| TB half-period | `tb_arb_beat_conservation.sv:8` | #25 → 20 MHz | #20.833 for 24 |
| comments | ddr_bus_arbiter, npx_path, content_window | docs | update notes |
| SDRAM_CLK_HZ | `Plex.sv` 120e6 | **not** clk_sys | no change |
| gamma_bus[20] | sys/video_mixer | bit index not MHz | no change |
| RAMBASE 32'h20000000 | sys_top | address | no change |

**Silent break class:** any counter using `N * 20` for µs/ms wall time, UART bit periods on clk_sys, SPI timeout in cycles, audio rate match F_SYS. Sweep gate: `tests/unit/test_clk_sys_20mhz_inventory.py`.

## 7. STA constraints before fit

- Product: `Plex.sdc` + `derive_pll_clocks` (existing).  
- Optional: `Plex_clk_pix.sdc` async groups — **commented** in QSF.  
- `make post-fit-timing` → `scripts/check_quartus_timing.py` **hard-fails negative slack**.  
- New: `--min-fmax-mhz` optional gate (e.g. 20 for product; 24 rejects current stub report).  
- timing_exclusion_baseline: **additive** fingerprints for the two `set_clock_groups` only.

## 8. What is applied vs proposed

| Item | State |
|------|--------|
| PLL out3 29.70 behind `PRESENT_CLK_PIX_PLL` | **APPLIED** default-OFF |
| Plex.sv clk_pix + CLK_VIDEO routing | **APPLIED** default-OFF |
| Plex_clk_pix.sdc + QSF commented recipe | **APPLIED** default-OFF |
| VIDEO_AR ← FRAME_W:H | **APPLIED** (640×480 QSF → 4:3 still; set FRAME 1280×720 for 16:9) |
| clk_sys frequency change | **NOT applied** (stay 20) |
| PPC=2 N-wide store path | **APPLIED** (cherry-pick fe28e600; default-OFF MULTI) |
| Quartus fit | **NOT run** (parent HELD) |

## 9. Fit recipe (parent grant only)

```
VERILOG_MACRO PRESENT_MULTI_PIXEL=1
VERILOG_MACRO PRESENT_PX_PER_CLK=2   # only after N-wide store; else rate wall at PPC=1
VERILOG_MACRO PRESENT_CLK_PIX_PLL=1
SDC_FILE Plex_clk_pix.sdc
# optional 60p: PRESENT_CLK_PIX_74_25=1
```

Post-fit: `make post-fit-timing STA_RPT=...` and  
`python3 scripts/check_quartus_timing.py --sta-rpt ... --min-fmax-mhz 20`  
plus inspect general[3] Fmax ≥ 29.70 when pix enabled.


## Fmax provenance (2026-08-03 parent challenge)

Retained `output_files/Plex.sta.rpt` **23.17 MHz** is **STUB-IN**:
- `Plex.fit.rpt` decode_stub:stub hits = **2025**
- ALMs **21252** (stub class), not nostub ~14k
- Path owner in plain STA export: **unknown** (no From/To nodes)
- Historical pair: stub **23.46** (`8fdf440f`) / nostub **32.59** (`c74c6863`)

**clk_sys@24 remains blocked on stub-in evidence.** After w-nostub land + new fit,
re-score using `FIT_PREREG_POST_NOSTUB.md` P1–P9. Do not promote 24 from 32.59 folklore alone.
