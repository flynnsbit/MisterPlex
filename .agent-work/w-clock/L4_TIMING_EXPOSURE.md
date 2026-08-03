# L4 timing exposure (geometry, not clock)

**MEASURE_REF:** detached `035fae51`  
`git rev-parse --abbrev-ref HEAD` → `HEAD` (DETACHED)  
`git rev-parse HEAD` → `035fae51b7d36160f865efcee217a6fde49532f8`  
Pin: `MisterPlex/MisterPlex-wt-clock-pin-035fae51`

**No Quartus fit by w-clock.** All Fmax numbers below labelled MEASURED prior vs INFERRED.

Ship PLL remains **clk_sys=20.000 MHz** (period 50 ns). PLL kit PARKED.

---

## What L4 enable actually turns on (SOURCE)

From `Plex.qsf` commented recipe + `Plex.sv` / `present_core.sv` on pin:

| Macro | Effect |
|---|---|
| `PLEX_PRESENT_720P_L4=1` | Instantiates live path (already L3 noprune when flag on): `u_beam_720p24`, `u_content_window`, wires content_w/h from mux |
| `FABRIC_NATIVE_720P_GEOM=1` | Mux forces content/DE/coded **1280×720**, strides 1280/640 |
| `FRAME_W=1280` `FRAME_H=720` | Parameterises `present_core`, `ddr_frame_store`, `stream_path` |

Default product (active macros): FRAME 640×480, L4 commented → **not** this exposure.

---

## Geometry delta (constants)

| Signal / param | Baseline Template | L4 720p24 |
|---|---|---|
| Beam DE | H_DE=529 (10b local) | **H_DE=1280**, V_ACT=720 |
| Beam total | H_TOTAL≈1182 class | **H_TOTAL=1312**, V_TOTAL=**762** |
| hc / vc | `reg [10:0]` | same **11b** (1312 < 2048) — **width unchanged** |
| h_last / compare | 11b == 11b | same width; **activity** higher (more unique compare values) |
| FRAME_W clog2 | 10 | **11** (`X_W`) |
| FRAME_H clog2 | 9 | **10** (`Y_W`) |
| Y_LINE_QWORDS | 640/8=**80** | 1280/8=**160** |
| C_LINE_QWORDS | 40 | **80** |
| Y_PLANE_QWORDS | 640×480/8 | **1280×720/8 = 115200** (const fold) |

---

## Timing-relevant paths (named signals)

### A. Sameclk clk_sys — NEW / grown with L4

| # | Module | Signals | Mechanism | Why worse at 1280 |
|---|---|---|---|---|
| A1 | `present_content_window` | `hc` → `store_x_prod` → `store_x` | **11×20 mul** every `ce_pix`: `{21'd0,hc}*{12'd0,sx_r}`; then add/clamp to `store_x` | **NEW product path** (L4 only). Baseline Template uses scale const, no window mul. Identity 1280→1280 keeps sx≈65536 but **mul still present**. |
| A2 | `present_content_window` | `py` → `store_y_prod` → `store_y` | same mul-shift on Y | same |
| A3 | `present_content_window` | `sx_num_ceil / hd_m1` → `sx_r` | **32b / 11b divide** into registered `sx_r` | Divide is **registered** (not hc combo). Recomputes when geom changes — **not** per-pixel critical if synth keeps it off pixel path. Still area/ALM pressure. |
| A4 | `present_beam_content_de` | `hc`/`vc` vs `hde_act`/`htot_act`/`vact_act`/`hs_s`… | 11b magnitude compares → HBlank/VBlank/HSync/VSync | Width same; **fanout** of `hc` grows (feeds window + DE + store). |
| A5 | `ddr_frame_store` | `rd_x`/`rd_y` (`X_W`/`Y_W`), `y_rd_addr`, line tag compare `y_line[*]==src_y` | wider index + tag compare | **+1 bit** X and Y vs 640×480; more routing on video read. |
| A6 | `ddr_frame_store` | YUV: `r_calc_w`/`g_calc_w`/`b_calc_w` | fixed mul tree on clk_sys | **Unchanged structure**; more instances if dual-read — check STA |
| A7 | `slice_hdr_parser` | `r_tc` → `residual_csum` | combo 16-fold ST_PLACE | **Unchanged by L4 geometry**. Still MEASURED prior owner on main (**csum_acc fix NOT on 035fae51**). |

### B. Related-edge clk_ddr → clk_sys (EXISTING class, larger tags)

| # | Signals | Prior MEASURED | L4 effect |
|---|---|---|---|
| B1 | `y_line[*]` → `y_line_v1[*]` | nostub dump slack **1.189** ns, rel **5.556** ns (clk_ddr→clk_sys) | `Y_W` 9→**10**: one more tag bit in CDC meta path |
| B2 | `c_line[*]` → `c_line_v1[*]` | slack **1.377** ns same dump | `Y_W-1` grows similarly |
| B3 | `fill_y * Y_LINE_QWORDS_W` → `y_addr` (clk_ddr) | const 80 vs **160** | wider mul on **clk_ddr** fill FSM — ddr Fmax risk, not clk_sys |

### C. Not a geometry Fmax issue (do not confuse)

| Item | Note |
|---|---|
| Glass 720p@60 | ascal / hdmi_clk — already live; L4 is **content** |
| PLL 24 MHz | PARKED; L4 beam math valid at 20 MHz (lower content frame rate) |
| HPS DDR3 hard IP | Do not raise; fabric only |
| `u_plxg_latch` with wr tied 0 | Little sequential depth until poller lives |

---

## Ranking (INFERRED — STA settles)

1. **Highest new sameclk risk:** A1/A2 `store_x_prod` / `store_y_prod` (first time in product netlist).  
2. **Highest known prior sameclk risk:** A7 residual_csum (main still has combo fold).  
3. **Related-edge watch:** B1/B2 y_line/c_line meta (already real paths).  
4. **ddr fill:** B3 address mul width — watch clk_ddr Fmax ≥ 90.

---

## MEASURED vs INFERRED

| Claim | Class |
|---|---|
| hc/vc are 11b; 1312 fits | MEASURED source |
| content_window 11×20 mul on ce_pix | MEASURED source |
| sx divide registered into sx_r | MEASURED source |
| residual_csum still combo on main@035fae51 | MEASURED source (no csum_acc latch) |
| prior residual path data delay 30.062 ns | MEASURED nostub path dump |
| y_line meta slack 1.189 ns | MEASURED prior related-edge dump |
| L4 Fmax number | **UNKNOWN until fit** |
| store_x mul delay vs residual | **UNKNOWN until fit** |
