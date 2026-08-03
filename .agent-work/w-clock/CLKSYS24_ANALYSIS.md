# clk_sys 24 MHz vs separate clk_pix — w-clock analysis

**Pin:** detached / branch base `8609fd78`  
**branch tip:** see git  
**PRE-REGISTER (before measure):** all four reviewer bullets CONFIRMED; HSync “already fixed” on 8609fd78 **REFUTED** by source.

---

## 0) HSync record correction (parent stale-task notice)

Parent: reviewer claims HSync already asserts 1288–1296 on `8609fd78`.

**My verification on `8609fd78` (this pin):** reviewer claim is **FALSE**.

| Source | Evidence |
|--------|----------|
| `present_beam_content_de.sv:34-35` | defaults `H_FP=32`, `H_SW=64` |
| `present_beam_content_de.sv:110-111` | `use_rt_geom` → `hs_s = hde_act + H_FP` (ignores `H_SYNC_*`) |
| `present_core.sv:276-285` | L4 passes `H_SYNC_S/E` (1288/1296) but **not** `.H_FP/.H_SW`; `use_rt_geom=1` |
| Arithmetic | `hs_s=1280+32=1312`, `h_last=1311` → **asserted_cycles=0** |

If honoured: `1288..1296` width **8**. The 1288–1296 numbers exist only as **ignored** parameters.

Per parent order: **I did not re-fix HSync on this branch.** The defect remains a **blocker for L4 enable** until someone lands the honour-H_SYNC / pass-H_FP fix (my `w-clock-hsync-fix` work is parked as optional).

VSync @ V_TOTAL=762 with defaults V_FP=8 V_SW=6: **asserts** 6 lines @ 728..733 — OK without fix.

---

## 1) Four reviewer bullets — verify/refute (`8609fd78`)

### Bullet A — L4 beam on clk_sys, not clk_pix → **CONFIRMED**

```
present_core.sv:285-286   u_beam_720p24 (.clk(clk), ...)
Plex.sv:838               present (.clk(clk_sys), ...)
pll_0002.v                outclk_0 = "20.000000 MHz" → clk_sys
```

L4 clocks/frame = 1312×762 = **999_744**  
fps @ 20 MHz = 20e6/999744 = **20.005121 Hz** (not 24).

### Bullet B — Active Mpix/s already > 20 → **CONFIRMED**

```
1280 * 720 * 24 = 22_118_400  (> 20e6)
1312 * 762 * 24 = 23_993_856  (full L4 raster @ exact 24.000 fps)
```

Even **active-only** exceeds clk_sys. Full L4 needs **~24.0 MHz** beam clock for ~24.006 Hz  
(`24e6/999744 = 24.006146`).

### Bullet C — clk_pix only MULTI; L4⊥MULTI → **CONFIRMED**

```
present_core.sv:249-250  $error L4 and PRESENT_MULTI_PIXEL mutually exclusive
present_core.sv:685+     PRESENT_MULTI_PIXEL owns present_npx_path + clk_pix unpack
Plex.sv:843-846          clk_pix_pll only under PRESENT_CLK_PIX_PLL; else clk_pix=clk_sys
```

No macro combo: L4 + real separate pix clock for the L4 beam.  
clk_pix PLL feed does **not** clock `u_beam_720p24`.

### Bullet D — CLK_VIDEO hardwired clk_sys → **CONFIRMED**

```
Plex.sv:969  assign CLK_VIDEO = clk_sys;
Plex.sv:970  assign CE_PIXEL  = ce_pix;
```

Even if RGB/HS/VS were produced in another domain, MiSTer video path still tags  
`CLK_VIDEO=clk_sys`. Separate pix domain requires this assign to change (and CE/HS/VS  
same-domain as CLK_VIDEO).

**Corollary (reviewer):** no current default-OFF recipe yields valid 720p24 scanout timing.  
**Agreed.**

---

## 2) Recommendation: **(a) retune clk_sys → 24 MHz** for first product L4 fit

| | (a) clk_sys = 24 MHz | (b) finish clk_pix domain |
|--|----------------------|---------------------------|
| New CDC | **None** (same domains, faster) | sys↔pix async FIFO + 2FF; store vs beam |
| CLK_VIDEO | Unchanged assign is **correct** | Must retarget + audit CE_PIXEL/HS/VS |
| L4 beam | Already on clk — **works** | Must rewire `.clk(clk_pix)` + store path |
| MULTI path | Optional later | Required complexity now |
| Fit risk | STA must close @24 (need Fmax≥24; nostub-class ~32 OK; stub 23.46 **FAIL**) | STA on two domains + placement |
| Design churn | PLL string + rate-sensitive constants | PLL + present_core + Plex.sv + SDC + tests |
| ARM-decode product | Fabric = scanout only; 24 MHz helps beam | Overkill for scanout-only |

**Recommend (a).** Parent inclination is correct. (b) is the right *architecture* for CEA 74.25 glass-native later; it is the wrong *first fit* while L4 is 1312×762 content into ascal.

**PRE-REGISTER STA (a):**  
- Product **nostub-class** netlist: **PASS @24** Fmax owner still `slice_hdr_parser` residual_csum (prior 32.59) — **unknown until fit**.  
- If **decode_stub** remains timing-critical (~23.46): **FAIL @24** — must nostub or pipeline residual before enabling.

---

## 3) Exact PLL change for (a)

`fpga/Plex_MiSTer/rtl/pll/pll_0002.v` — **both** altera_pll instances (flagged and product):

```
// was:
.output_clock_frequency0("20.000000 MHz"),
// become (under default-OFF macro PRESENT_CLK_SYS_24):
.output_clock_frequency0("24.000000 MHz"),
```

Suggested gate (product default stays 20):

```verilog
`ifdef PRESENT_CLK_SYS_24
`define MISTERPLEX_CLK_SYS_PLL_FREQ "24.000000 MHz"
`else
`define MISTERPLEX_CLK_SYS_PLL_FREQ "20.000000 MHz"
`endif
// ...
.output_clock_frequency0(`MISTERPLEX_CLK_SYS_PLL_FREQ),
```

QSF (commented recipe only):

```
#set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_SYS_24=1"
# Also enable L4 + FRAME_1280 only after HSync fix + stride guard + parent fit grant
```

**Do not** raise HPS/DDR3 hard-IP clocks. `outclk_2` stays 90 MHz. SDRAM macro path unchanged.

L4 result @ 24 MHz: fps = 24e6/999744 ≈ **24.006 Hz** (matches present_core comment intent).

---

## 4) clk_sys consumer inventory @ 20 MHz assumptions

### 4.1 Instantiated on clk_sys (Plex.sv) — rate scales with f; logic OK if cycle-pure

| Site | Consumer | 20→24 effect |
|------|----------|--------------|
| :128 | `hps_io.clk_sys` | SPI bit time is HPS-driven; core samples on clk_sys → **20% more samples/sec**. Usually OK; watch any **cycle-counted** SPI timeout (none found hardcoded to 20e6 in rtl). |
| :266 | `present_geom_latch` | cycle FSM — OK |
| :583 | `frame_ingest` | OK |
| :624 | `ddr_frame_store` / ddr_fr | OK; more DDR command issue rate from sys side |
| :671 | `audio_ingest` | wr side faster vs `clk_audio` — CDC FIFO; **check underrun/overrun margins** |
| :721 | `stream_path` (spath) | decode fabric faster — good if used; budgets in tests assume 20e6 |
| :838 | `present_core` | **beam fps scales** — desired for L4; colorbars/template also faster |
| :936 | `ddr_bus_arbiter.clk_m1` | consumer side of CDC — OK |
| :969 | `CLK_VIDEO` | video clock becomes 24 MHz — **required** for L4 |
| always blocks | playback cmd, sdram_test sync, host_owns_fs, act_cnt | edge FSMs — OK |

### 4.2 Hardcoded 20_000_000 / “20 MHz” in RTL (must update if 24 is product)

| File | What | Action if PRESENT_CLK_SYS_24 |
|------|------|------------------------------|
| `pll_0002.v` | outclk_0 string | **SoT change** |
| `pll.v` | comment 20 MHz | comment |
| `present_core.sv:202,221` | `.CLK_PIX_HZ(20_000_000)` keep-alive timing packs | tie to `ifdef` 24 |
| `present_core.sv:715` | `MP_CLK_PIX_HZ=20e6` else | ifdef |
| `present_video_timing_720p.sv:29` | default CLK_PIX_HZ | param from parent |
| `present_video_timing_960.sv:15` | default CLK_PIX_HZ | param |
| `present_pix_rate_match.sv:15` | F_SYS_HZ=20e6 | ifdef / param |
| `present_vtotal_bresenham.sv` | duties derived for **H=1182 @ 20e6** | **960 path only**; L4 unused. If 960+24 MHz without retune V duties → **wrong fps**. Gate: 960+SYS24 needs new DEN/num or disable bres. |
| `present_beam_content_de.sv` | comments fps @20 | comment |
| `present_npx_path.sv` | comments F_sys=20 | comment |
| `ddr_bus_arbiter.sv` | comments 20 MHz m1 | comment |
| `colorbars.sv` | H_LAST=637; ce_pix half-rate when !scandouble | Template fps rises ~20%; FBAR golden **may** be timing-sensitive on glass — parent eyes-on |

### 4.3 Tests / fixtures / gates that **encode** 20 MHz (will RED if PLL changes without test update)

| Path | Note |
|------|------|
| `tests/unit/test_720p_clk_ddr_arith.py` | asserts out0=20.000000 |
| `tests/unit/test_decode_throughput_gate.sh` | `stream_path_clock_hz == 20_000_000` |
| `tests/unit/test_p3_high_cabac_scope.py` | `CLK_SYS_HZ = 20_000_000` |
| `tests/unit/test_h264_cavlc_real_mb_cycles.sh` | HEADLINE_*_AT_20MHz |
| `tests/rtl/h264_cavlc_real_mb_cycles_tb.cpp` | budgets @20 MHz |
| `tests/rtl/ddr_beat_*_tb.cpp` | HALF_SYS_PS=25000 (20 MHz) |
| `tests/fixtures/p3_multinal/*_decode_throughput_v1.json` | clock_source 20 MHz |
| `docs/decode-throughput.md`, `cdc-crossing-inventory.md`, … | narrative |

### 4.4 Explicitly **not** 20 MHz (safe)

| Domain | Clock | Notes |
|--------|-------|-------|
| clk_ddr | 90 MHz | unchanged |
| clk_sdram | 100/120/… macro | own HZ param; refresh math uses SDRAM_CLK_HZ |
| clk_audio / CLK_AUDIO | MiSTer audio clock | separate |
| FPGA_CLK*_50 | 50 MHz ref | PLL ref stays |

### 4.5 How to detect a silent 20 MHz consumer break

1. **Static gate (this land):** `tests/unit/test_clksys_20mhz_inventory.py` — fails if product QSF enables `PRESENT_CLK_SYS_24` while inventory allowlist not updated; lists every `20_000_000` in rtl/.  
2. **Sim:** existing unit suite — decode throughput JSON and ddr_beat half-period must be dual-rated or ifdef.  
3. **STA one-pass after fit:** `scripts/sta_onepass_interrogation.sh` — require Fmax(clk_sys)≥24.0, owner ≠ decode_stub.  
4. **HW (parent):** L4 enable → HDMI fps ~24.0 (not 20.0); FBAR template path regression if colorbars rate assumed; audio underrun counter; SPI present still 240p ceiling (unchanged path).  
5. **Negative twin:** build with SYS24 but leave `test_decode_throughput_gate` at 20e6 → must RED until gate updated (proves inventory coupling).

---

## 5) Fate of landed `PRESENT_CLK_PIX_PLL` (29.70 outclk_3)

| Option | Verdict |
|--------|---------|
| Keep default-OFF as “progress” | **No** — dead path; L4 never uses it; reads as done |
| Repurpose outclk_3 as 24 MHz | **No** — L4 needs **clk_sys**/CLK_VIDEO=24, not a spare counter |
| **Revert** PLL 4th clock + `Plex_clk_pix.sdc` + Plex.sv outclk_3 wiring | **Yes** for first-fit honesty |
| Keep | `test_720p_clk_ddr_arith.py` DDR MB/s + CEA arithmetic docs |

**Recommendation: REVERT** the separate pix-PLL machinery from the product tree; replace with **`PRESENT_CLK_SYS_24`** default-OFF on outclk_0. Preserve DDR/CEA arith tests (rewrite PLL asserts for sys-24 recipe).

---

## 6) Product path reminder (parent fabric scope)

ARM decodes 720p → I420 DDR banks → fabric YUV→RGB + L4 beam.  
Clocking goal = **real 1280×720 content raster @ ~24 Hz into ascal**, not glass-native 74.25.

Minimum coherent enable list (not this commit’s job to complete):  
1. HSync fix (still open on 8609fd78)  
2. w-mem stride guard  
3. `PRESENT_CLK_SYS_24` + STA PASS≥24  
4. L4 + FRAME_1280 QSF under parent fit grant  

---

## 7) PRE-REGISTER hits/misses

| Prediction | Result |
|------------|--------|
| Bullet A–D all true | **HIT** |
| HSync already fixed on 8609fd78 | **MISS (reviewer/parent)** — still width 0 |
| VSync OK at 762 | **HIT** |
| (a) preferred | **HIT** (analysis) |
| Fmax@24 | **unknown until fit** |

---

## 8) Applied on this branch (vs analysis-only)

| Change | Status |
|--------|--------|
| Revert PRESENT_CLK_PIX_PLL / outclk_3 / Plex_clk_pix.sdc | **DONE** |
| PRESENT_CLK_SYS_24 default-OFF on outclk_0 | **DONE** (`pll_0002.v`) |
| QSF commented recipe | **DONE** |
| KEEP_CLK_SYS_HZ / MP_CLK_PIX_HZ follow SYS_24 | **DONE** (`present_core.sv`) |
| test_720p_clk_ddr_arith L4+SYS24 | **DONE** |
| test_clksys_20mhz_inventory | **DONE** |
| HSync fix | **NOT** applied (parent STOP) |
| Quartus fit | **NOT** run (HELD) |

**Product default remains 20 MHz** — no behavior change until parent enables macro + fit grant.
