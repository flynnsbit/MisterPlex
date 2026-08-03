# w-nostub — QSF / fit beam constants (LOCKED numbers; wire GREEN after elab)

**Owner of numbers:** w-clock `w-clock-bump`  
**Cadence decision:** **30 Hz** core raster (parent 2026-08-03)  
**Fit strategy:** ascal-native true 960×540 DE @ clk_sys 20 MHz → HPS HDMI 1280×720@60  

Do **not** invent alternate totals without w-clock + parent.  

**rd-duck:** `present_video_timing_960.sv` is a **constant bundle only** — not a fit
candidate alone. Fit requires `PRESENT_BEAM_960` → `present_beam_content_de` +
identity store in `present_core` (elab gate: `test_present_beam_960_elab.sh`).

---

## Required defines (first fit)

| Macro | Value |
|-------|-------|
| `PRESENT_BEAM_960` | **ON** |
| `FRAME_W` / `FRAME_H` | **960** / **540** |
| `PRESENT_MULTI_PIXEL` | **OFF** (mutex with BEAM_960) |
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
| fps_eff_milli | **30000** | RTL longint oracle (20e9/666648 trunc) |
| fps float | **30.0008** | 20e6/666648 |
| active Mpix/s | **15.552** | 960×540×30.0008 |

## true_de gate (hard)

- `H_DE == content_w == 960` and `V_ACTIVE == content_h == 540`
- Identity store (no stretch across larger DE)
- **Forbidden:** Template `H_DE=529`, canvas `H_DE=1280` with 960 island  
- Evidence: w-scaler `PRODUCT_30_V564` + w-clock oracle `true_de=1`  
- Contract: `tests/unit/test_true_content_de_contract.sh` (w-scaler)  

## Optional film companion (not first-fit default)

| | Value |
|--|------:|
| H_TOTAL | 1182 (same) |
| V_TOTAL | **705** |
| fps | 24.0007 |
| Macro/runtime | w-scaler `PRESENT_BEAM_24_V705` / `rt_vtotal=705` |
| MODE=2 legacy | 1389×600 → fps_milli SV trunc **23998** (20e9/833400; allow 23997..23998) |

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
| Timing constants | `rtl/present_video_timing_960.sv` (longint FPS; not solo fit) |
| Beam raster | `rtl/present_beam_content_de.sv` |
| Core wire | `rtl/present_core.sv` `PRESENT_BEAM_960` |
| Oracle | `tests/unit/test_present_beam_960_oracle.sh` |
| Elab | `tests/unit/test_present_beam_960_elab.sh` |
| Contract JSON | `assets/ascal_native_beam_contract.json` |

## verilog / QSF snippet (illustrative)

```tcl
# ascal-native 960x540@30 — w-clock locked
set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=960"
set_global_assignment -name VERILOG_MACRO "FRAME_H=540"
# do NOT set PRESENT_MULTI_PIXEL or PRESENT_CLK_PIX_PLL
```

## Host gates before fit grant

```
bash tests/unit/test_present_beam_960_arith.sh
bash tests/unit/test_present_beam_960_oracle.sh
bash tests/unit/test_present_beam_960_elab.sh
```

**Stale log:** `.agent-work/w-clock/npx_full_raster_run.txt` must not exist.

## B2b / runtime geom (w-clock follow-up)

- Raster SoT: `present_beam_content_de` only. Do **not** require `u_timing_960` in hierarchy.
- `present_video_timing_960` = math pack for oracles; may remain in `files.qip`.
- Runtime geom ports default **OFF** (`use_rt_geom=0`). Film V=705 via `use_rt_vtotal` when host wires it.
- STA prereg: `assets/ascal_native_sta_prereg.json` schema 3 (564 + 705 + runtime UNKNOWN).
- Report: `.agent-work/w-clock/RUNTIME_VARIABLE_RASTER_STA.md`

