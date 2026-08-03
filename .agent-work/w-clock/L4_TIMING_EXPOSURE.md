# L4 timing exposure (geometry, not clock)

**MEASURE_REF:** detached `035fae51`  
`git rev-parse --abbrev-ref HEAD` → `HEAD` (DETACHED at pin) / branch `w-clock-sta-fitprep`  
`git rev-parse HEAD` → `035fae51b7d36160f865efcee217a6fde49532f8`  
Pin tree: `MisterPlex-wt-clock-sta` (or pin-035fae51)

**No Quartus fit by w-clock.** Fmax numbers below: MEASURED prior netlist vs INFERRED.

Ship PLL remains **clk_sys=20.000 MHz** (period 50 ns). PLL kit PARKED.

---

## What L4 enable turns on (SOURCE)

### QSF recipe (commented — default OFF)

`fpga/Plex_MiSTer/Plex.qsf:83-97` active macros still:
```
FRAME_W=640
FRAME_H=480
```
Commented enable recipe:
```
#set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"
#set_global_assignment -name VERILOG_MACRO "FABRIC_NATIVE_720P_GEOM=1"
#set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"
#set_global_assignment -name VERILOG_MACRO "FRAME_H=720"
```

### Instantiation behind the flag

| Module | Where | Flag |
|---|---|---|
| `u_beam_720p24` (`present_beam_content_de`) | `present_core.sv:266` | `PLEX_PRESENT_720P_L4` |
| `u_content_window` (`present_content_window`) | `present_core.sv:417` | `PLEX_PRESENT_720P_L4` |
| geom mux / latch / PLXG | `Plex.sv:238+` | `PLEX_PRESENT_720P_L4` |

Beam constants (`present_core.sv:237-244`):
```
L4_H_DE=1280  L4_V_ACT=720  L4_H_TOTAL=1312  L4_V_TOTAL=762
```

`present_core.sv:224-226` elab check: L4 **requires** FRAME_W=1280 FRAME_H=720.

---

## Geometry delta

| Signal / param | Baseline 640×480 | L4 720p |
|---|---|---|
| Beam DE | Template H_DE class | **H_DE=1280**, V_ACT=720 |
| Beam total | ~1182 class | **H_TOTAL=1312**, V_TOTAL=**762** |
| hc / vc | `reg [10:0]` | same **11b** (1312 < 2048) |
| FRAME clog2 X/Y | 10 / 9 | **11 / 10** |
| Y_LINE_QWORDS | 80 | **160** |

---

## Timing-relevant cones (named)

### A. Sameclk clk_sys — NEW / grown with L4

| # | Module:line | Signals | Mechanism |
|---|---|---|---|
| A1 | `present_content_window.sv:200` | `store_x_prod = {21'd0,read_hc}*{12'd0,sx_r}` | **11×20 mul** every pixel (`ce_pix`) |
| A2 | `present_content_window.sv:209` | `store_y_prod` same form on `py_clamped` | Y mul-shift |
| A3 | `present_content_window` sx_r path | divide into **registered** `sx_r` | Not per-pixel if kept off combo path |
| A4 | `present_beam_content_de` via `u_beam_720p24` | hc/vc vs hde/htot/vact | 11b compares; higher activity |
| A5 | `ddr_frame_store` | wider `X_W`/`Y_W`, y_line tags | +1 bit index/tag |
| A6 | `slice_hdr_parser` | `r_tc` → `residual_csum` | **Unchanged by L4 geom**. Prior MEASURED owner on nostub |

### B. Related-edge clk_ddr → clk_sys

| # | Signals | L4 effect |
|---|---|---|
| B1 | `y_line[*]` meta | Y_W 9→10 |
| B2 | `c_line[*]` meta | grows with chroma tags |
| B3 | fill addr × Y_LINE_QWORDS 80→160 | clk_ddr mul width |

### C. Not geometry Fmax

Glass already 720p@60 via ascal. L4 = **content** 1280×720. PLL 24 MHz PARKED.

---

## Ranking (INFERRED — STA settles)

1. **Highest new sameclk risk:** A1/A2 `store_x_prod` / `store_y_prod`  
2. **Highest known prior sameclk risk:** A6 residual_csum (combo fold on bare main; csum_acc latch on this branch)  
3. **Related-edge watch:** B1/B2  
4. **ddr fill:** B3 — watch clk_ddr Fmax ≥ 90

---

## MEASURED vs INFERRED

| Claim | Class |
|---|---|
| L4_H_*=1280/1312/762 source | MEASURED source |
| content_window mul L200 | MEASURED source |
| residual prior data delay 30.062 ns | MEASURED nostub path dump (different netlist) |
| L4 Fmax number | **UNKNOWN until fit** |
| store_x mul delay vs residual | **UNKNOWN until fit** |
