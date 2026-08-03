# Video mode 720p — w-clock deliverable

## Claim (what lands)

Under `PRESENT_MULTI_PIXEL` (default **OFF**), when `use_ext` (has_frame && !force bars):

| Signal | Source | Value |
|--------|--------|-------|
| Active DE | `present_beam_ppc` | **1280 × 720** |
| H_TOTAL / V_TOTAL | CEA-861 720p | **1650 × 750** |
| HSync | [1390,1430) | 40 px |
| VSync | [725,730) | 5 lines |
| Pixel path | store N-wide → `present_npx_path` → RGB | 1 px per CE_PIXEL |
| `ce_pix` | hard 1 | product scandouble class |

When macro is **OFF** (shipping / `d1b24e0c` class): **unchanged**. Template `H_DE=529` in `present_core.sv` + `colorbars` remains the FBAR/DE_LAG lock. Do not move it.

## Honest rate (rule 0)

MiSTer accepts **1 RGB sample per CE_PIXEL**. With `clk_pix == clk_sys == 20 MHz` and CE=1:

```
output pixel rate ≤ 20.0 Mpix/s   (independent of PX_PER_CLK)
CEA 720p24 full raster need      = 1650×750×24 = 29.70 Mpix/s
CEA 720p60 full raster need      = 74.25 Mpix/s
same-clock fps_eff               = 20e6 / (1650×750) ≈ 16.16 Hz
```

So this commit delivers a **genuine 1280×720 active geometry**, not 24/60 Hz CEA refresh.
`present_video_timing_720p` exposes `fps_eff_milli=16161` and `cea_24_needs_faster_pix=1` at 20 MHz.

2 px/clk still lowers **fabric** work (store/YUV groups) when the beam is backpressured by the serializer — it does **not** raise HDMI pixel rate on the same clock.

Real 24/60 Hz needs a faster `clk_pix` (see `CLK_PIX_PLL_PLAN.md`) — **not applied** without parent fit grant.

## FBAR / H_DE=529

`present_core.sv` keeps:

```systemverilog
localparam H_DE = 10'd529;  // Template — FBAR/DE_LAG class
```

Multi-pixel path does **not** edit that constant. 720p DE is owned only by `present_beam_ppc` under the ifdef, and only drives `HBlank/HSync/VBlank/VSync` when `use_ext`.

## H ownership vs w-scaler

| Concern | Owner |
|---------|--------|
| Glass H counter, +PPC step, H_DE compare | **w-clock** `present_beam_ppc` |
| Glass → store map, CODED 1280 read geom | **w-scaler** (`FABRIC_NATIVE_720P_GEOM`) |
| Y qword+1 dual-port for straddle | **shared**: `line_buf_ram` port B; beam guarantees `x0%PPC==0` on 1280 DE for PPC∈{2,4} so active straddle does not occur; hi is safety net |

If lanes disagree on who steps H, escalate to parent — do not dual-own.

## CDC

Only `async_fifo` gray pointers cross `clk_sys` ↔ `clk_pix` inside `present_npx_path`.
Soak: `tests/unit/test_present_npx_cdc_soak.sh` (4096 groups, unrelated periods, RGB order).

Same-clock bring-up ties `clk_pix=clk`. Beam gated by `in_ready` so fill ≤ drain.

## Quartus DCE

Chain is live when `use_ext`: beam → `fstore_rd_*` → `ddr_frame_store` N-ports → `u_mp_npx_path` → `r/g/b` + blanks.
`u_mp_timing` has `(* noprune *)` outputs; post-fit hierarchy must show non-zero rows for:

- `u_mp_timing`, `u_mp_beam`, `u_mp_npx_path`, `fstore` / `gen_rd_npx_wide`

## Parent verification (device — parent only)

```bash
# QSF / defines for integration fit only (NOT default):
#   `define PRESENT_MULTI_PIXEL
#   `define PRESENT_PX_PER_CLK 2
#   + w-scaler FABRIC_NATIVE_720P_GEOM / FRAME 1280 as coordinated
#   + fabric pattern / idle so has_frame=1 (use_ext)

DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
scripts/hdmi_capture_idle.sh /path/to/capture.png
# Expect: active area ~1280×720 class (not 529-wide Template bars).
# Refresh may be ~16 Hz core until clk_pix PLL; HDMI/ascal may mask.
# map.rpt: u_mp_beam / u_mp_npx_path / u_mp_timing rows > 0
```

Soft-skip ≠ PASS. Parent scores glass.
