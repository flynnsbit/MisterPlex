# L4 HSync fix (rd-duck #1) — CONFIRMED + FIXED

base: 8609fd78  branch: w-clock-hsync-fix

## Verification (source)
present_beam_content_de.sv use_rt_geom=1 used H_FP=32/H_SW=64 defaults,
ignoring H_SYNC_S/E. L4: hs_s=1280+32=1312, h_last=1311 → asserted_cycles=0.

present_core.sv passed H_SYNC_S=1288 E=1296 (from L4_H_FP_P=8/SW=8) but not
H_FP/H_SW — silent ignore of a passed parameter.

## VSync
V_FP=8 V_SW=6 → vs 728..733 (6 lines), v_last=761. ASSERTS correctly even
pre-fix. Same class still fixed via V_FP_RT from V_SYNC_*.

## Fix chosen
Derive H_FP_RT/H_SW_RT from H_SYNC_S−H_DE / H_SYNC_E−H_SYNC_S when valid
(H_SYNC_REL_OK). Falls back to H_FP/H_SW. Why not only wire H_FP in
present_core? That leaves the footgun class (absolute H_SYNC_* silently
ignored). Honouring the relative meaning of passed H_SYNC_* is the real
defect fix. Also pass H_FP/H_SW from present_core for consistency.

## RED→GREEN
unfixed twin: test_present_beam_hsync true rc=1 (l4_hs_width got=-1/0)
fixed: true rc=0 exact width 8 start 1288; VSync 6 @728; 320 width 8 @328

## Rasters
| Path | H×V | f_pix@24 | PLL |
|------|-----|----------|-----|
| L4 PLEX_PRESENT_720P_L4 | 1312×762 | 23.993856 MHz (exact 24fps) / 24.0→24.006Hz | default PRESENT_CLK_PIX_PLL |
| CEA MULTI_PIXEL pack | 1650×750 | 29.70 MHz | PRESENT_CLK_PIX_CEA_29_70 |
| CEA VIC4 60 | 1650×750 | 74.25 MHz | PRESENT_CLK_PIX_74_25 |

L4 beam still clocks from clk_sys@20 today → ~20.005 fps until pix domain land.

## PPC=2
present_npx_path group-write: Peak F_sys*PPC is real in that module.
present_core forces PRESENT_PPC==1 until ddr_frame_store N-wide — product unlock aspirational.
