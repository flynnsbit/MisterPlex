# Clock decision + 20 MHz inventory — w-clock @ 842e45c9 / tip see git

## 1) Decision: **(a) retune clk_sys → 24 MHz** for product L4 present

### Arithmetic (two rasters — do not conflate)

| Path | Totals | f for 24 fps | Who clocks it on main |
|------|--------|--------------|------------------------|
| **L4 product** `PLEX_PRESENT_720P_L4` | **1312 × 762** | 1312×762×24 = **23.993856 MHz** | **clk_sys** (`u_beam_720p24.clk` ← `present.clk` ← `clk_sys`) |
| MULTI / CEA pack | 1650 × 750 | **29.700000 MHz** | would need clk_pix + MULTI (⊥ L4) |
| Active-only lower bound | 1280 × 720 | **22.118400 MHz** | — |

@ clk_sys=20 MHz, L4 fps = 20e6/999744 = **20.005 Hz** (not 24).  
@ clk_sys=24 MHz, L4 fps = 24e6/999744 = **24.006 Hz**.

PPC=1 @20 = 20 Mpix/s < 22.12 active and < 23.99 L4 full — **throughput wall on clk_sys alone at 20**.

### Arm (a) clk_sys = 24 MHz, keep single domain

| | |
|--|--|
| Change | PLL out0 `"24.000000 MHz"` behind default-OFF `PRESENT_CLK_SYS_24` (not landed this commit — inventory first) |
| CDC | **None new** |
| CLK_VIDEO | stays `clk_sys` — coherent |
| STA risk | Need Fmax(clk_sys) ≥ 24. Prior nostub-class ~32.59 OK; stub-class ~23.46 **FAIL**. Owner must be named post-fit. |
| Consumers | See §2 — every 20 MHz assumption must be dual-rated or gated |

### Arm (b) finish separate clk_pix @ 29.7 (CEA) or 24 (if mis-aimed at L4)

| | |
|--|--|
| Change | Wire L4 beam to clk_pix **or** drop L4 for MULTI CEA; fix CLK_VIDEO (done this land under flag); store↔pix CDC |
| CDC | sys↔pix async FIFO (exists in `present_npx_path` for MULTI only); L4 store path has **no** pix-domain beam today |
| L4⊥MULTI | `$error` if both — **no macro combo** gives L4 + separate pix today without RTL surgery |
| STA risk | Two domains + placement; more than (a) |
| Cost | present_core rewire, Plex.sv, SDC already default-OFF |

### Why (a) wins for **ARM-decode + fabric present** product

1. Product L4 raster is **1312×762 on clk_sys**, not 1650×750.  
2. 24 MHz closes L4@24 with **zero new CDC**.  
3. (b)’s 29.7 MHz solves a **different** raster (MULTI) that is mutually exclusive with L4.  
4. CLK_VIDEO hardwire is fixed under flag for future (b)/MULTI — does not make (b) the first fit.

**PRE-REGISTER STA (a):** nostub-class PASS @24 unknown until fit; if decode_stub owns Fmax ~23.46 → FAIL.

---

## 2) Exhaustive 20 MHz consumer inventory (RTL + tests)

Values at **24 MHz** column = what that site needs if clk_sys becomes 24 (or N/A if cycle-pure).

### 2.1 PLL / clocks (SoT)

| File:line | What | @20 | @24 need |
|-----------|------|-----|----------|
| `rtl/pll/pll_0002.v:67,137` | `output_clock_frequency0` | `"20.000000 MHz"` | `"24.000000 MHz"` under flag |
| `rtl/pll.v:8` | comment | 20 MHz | comment |
| `Plex_clk_pix.sdc:12` | comment clk_sys | 20 | comment (flag path) |

### 2.2 Present / beam (rate-sensitive)

| File:line | What | @20 | @24 need |
|-----------|------|-----|----------|
| `present_core.sv:202,221` | keep timing `.CLK_PIX_HZ(20_000_000)` | 20e6 | **24_000_000** when SYS24 |
| `present_core.sv:745` | `MP_CLK_PIX_HZ` else branch | 20e6 | 24e6 if sys-tied |
| `present_video_timing_720p.sv:29` | default `CLK_PIX_HZ` | 20e6 | param from parent |
| `present_video_timing_960.sv:15` | default `CLK_PIX_HZ` | 20e6 | param |
| `present_pix_rate_match.sv:15` | `F_SYS_HZ` | 20e6 | **24e6** (THRESH scales) |
| `present_vtotal_bresenham.sv:3-39` | duties for **H=1182 @ 20e6** | DEN=1773 nums for NTSC/exact | **Re-derive duties** for H=1182 @24e6 or disable 960+SYS24; L4 unused |
| `present_beam_content_de.sv:7,19` | comments fps @20 | docs | docs |
| `present_npx_path.sv:6` | comment F_sys=20 | docs | docs |
| `present_content_window.sv:20-22` | comments | docs | docs |
| `ddr_frame_layout_params.svh:59` | `DDR_FRAME_720P24_CLK_SYS_HZ=24e6` | already 24 target | OK |

### 2.3 clk_sys consumers that are **cycle-pure** (wall-time scales 20→24 automatically)

| Site | Module | Effect @24 |
|------|--------|------------|
| `Plex.sv` hps_io `.clk_sys` | SPI sample rate +20% | Usually OK; no 20e6 constant found in hps_io path |
| present_core / frame_ingest / stream_path / audio_ingest wr | FSMs | OK; audio CDC vs clk_audio — watch underrun |
| ddr_frame_store / arbiter clk_m1 | more m1 cycles/s | OK; sticky ready already handles ddr@90 |
| act_cnt LED blink | ~20% faster blink | cosmetic |
| colorbars / template beam | higher template fps | FBAR eyes-on |
| sdram_* sync 2FF on clk_sys | OK | |

### 2.4 Explicitly **not** clk_sys 20 MHz

| Domain | Rate | Notes |
|--------|------|-------|
| clk_ddr | 90 MHz | unchanged |
| clk_sdram | macro (100–142) | `SDRAM_CLK_HZ`; tRCD uses *20 ns* DRAM spec not 20 MHz |
| CLK_AUDIO | MiSTer audio | separate |
| refclk | 50 MHz | PLL ref |

### 2.5 Tests / fixtures encoding 20e6

| Path | Action if SYS24 product |
|------|-------------------------|
| `tests/unit/test_720p_clk_ddr_arith.py` | dual-assert default 20 + optional 24 |
| `tests/unit/test_decode_throughput_gate.sh` | `stream_path_clock_hz == 20_000_000` |
| `tests/unit/test_p3_high_cabac_scope.py` | `CLK_SYS_HZ = 20_000_000` |
| `tests/fixtures/p3_multinal/*_decode_throughput_v1.json` | clock_source strings |
| `tests/rtl/*_tb.cpp` half-period 25000 ps | 20 MHz sim timebase |

### 2.6 Detection strategy (silent break)

1. `test_clksys_20mhz_inventory.py` (this land) — allowlist of RTL 20e6 sites; RED if QSF enables SYS24 without recipe.  
2. Throughput gate must be updated same PR as product SYS24.  
3. STA one-pass: Fmax≥24, owner ≠ decode_stub.  
4. Parent HW: L4 fps ~24; audio underrun; FBAR template.

---

## 3) This land (applied)

| Item | Status |
|------|--------|
| Decision doc + inventory | done |
| `CLK_VIDEO` ← `clk_pix_pll` under `PRESENT_CLK_PIX_PLL` | done |
| Aspect ← FRAME_W:FRAME_H (not hardcoded 4:3) | done |
| RED/GREEN aspect test | done |
| CLK_VIDEO static test | done |
| PRESENT_CLK_SYS_24 PLL edit | **not** this commit (decision only; inventory must land first) |
| Revert clk_pix kit | **not** (parent merged it; keep default-OFF; CLK_VIDEO now coherent with it) |

## 4) HSync

Parent: already fixed on main — **withdrawn**. No work.
