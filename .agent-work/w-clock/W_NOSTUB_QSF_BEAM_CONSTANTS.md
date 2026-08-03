# w-nostub — QSF / fit beam constants (LOCKED)

**Owner of numbers:** w-clock `w-clock-bump`  
**Cadence decision:** **30 Hz** core raster (parent 2026-08-03)  
**Fit strategy:** ascal-native true 960×540 DE @ clk_sys 20 MHz → HPS HDMI 1280×720@60  

Do **not** invent alternate totals without w-clock + parent.  

---

## Required defines (first fit)

| Macro | Value |
|-------|-------|
| `PRESENT_BEAM_960` | **ON** |
| `PRESENT_MULTI_PIXEL` | **OFF** |
| `PRESENT_CLK_PIX_PLL` | **OFF** |
| `PRESENT_CLK_PIX_30` | **OFF** |

## Frame geometry (primary 30A)

| Constant | Value | Notes |
|----------|------:|-------|
| `H_DE` | **960** | must equal content_w (`true_de=1`) |
| `V_ACTIVE` | **540** | must equal content_h |
| `H_TOTAL` | **1182** | Hblank = 222 |
| `V_TOTAL` | **564** | Vblank = 24 |
| `H_SYNC_S` | **992** | 960+32 |
| `H_SYNC_E` | **1056** | pulse 64 |
| `V_SYNC_S` | **548** | 540+8 |
| `V_SYNC_E` | **554** | pulse 6 |
| `CLK_SYS` | **20_000_000** | Hz |
| `CE_PIX` | **1** | every clk_sys |
| fps | **30.0008** | `20e6/(1182*564)` = 20e6/666648 |
| active Mpix/s | **15.552** | 960×540×30.0008 |

## true_de gate (hard)

- `H_DE == content_w == 960` and `V_ACTIVE == content_h == 540`
- Identity store (no stretch across larger DE)
- **Forbidden:** Template `H_DE=529`, canvas `H_DE=1280` with 960 island  
- Evidence: w-scaler `PRODUCT_30_V564` RTL count → `true_de=1 de_w_max=960 de_lines=540`  
- Contract: `tests/unit/test_true_content_de_contract.sh` (w-scaler) product rc=0, RED island rc≠0  

## Optional film companion (not first-fit default)

| | Value |
|--|------:|
| H_TOTAL | 1182 (same) |
| V_TOTAL | **705** |
| fps | 24.0007 |
| Macro/runtime | w-scaler `PRESENT_BEAM_24_V705` / `rt_vtotal=705` |

## STA prereg (before fit)

See `assets/ascal_native_sta_prereg.json`.  
**Prediction:** meet 20 MHz setup/hold with margin unknown until `Plex.sta.rpt`.  
**Miss:** Fmax_sys < 20 or neg slack → HARD FAIL; no BUILD_OK invention.

## B1 (wide-group FIFO)

| Path | Need | Peak | B1 |
|------|-----:|-----:|----|
| First fit 1px CE=1 | 15.55 | 20.0 | **not required** |
| MULTI_PIXEL serialize | 15.55 | 13.33 | **required** (fixed → 40) |
| MULTI_PIXEL wide-group | 15.55 | 40.0 | already green, OFF |

## RTL sources

| Role | Path |
|------|------|
| Timing constants | `fpga/Plex_MiSTer/rtl/present_video_timing_960.sv` (w-clock) |
| Beam emitter | `present_beam_content_de.sv` (w-scaler; defaults 1182×564) |
| Contract JSON | `assets/ascal_native_beam_contract.json` |

## verilog / QSF snippet (illustrative)

```tcl
# ascal-native 960x540@30 — w-clock locked
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
# do NOT set PRESENT_MULTI_PIXEL or PRESENT_CLK_PIX_PLL
```

Wire `present_core` / colorbars replacement is **parent grant** with this card.

---

**Stale log:** `.agent-work/w-clock/npx_full_raster_run.txt` must not exist (HARD FAIL landmine).
