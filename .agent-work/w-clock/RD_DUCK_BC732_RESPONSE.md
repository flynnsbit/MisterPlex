# Response to bc732231-era audit (tip ≥ 4b23dc15)

## Stall TB
- Was: sequential exp_id on R only (weak).
- Now: queue scoreboard R/G/B per lane, mid-stream re-stall, post-reset window,
  RED FAULT_LANE_SWAP (count-ok order-bad → FAIL).

## present_video_timing_960
- Still constants-only **by design** (banner says NOT solo fit).
- 32-bit overflow **fixed** (longint FPS) in a1ee14e3; oracle fps_milli=30000.
- Raster candidate = `present_beam_content_de` + `PRESENT_BEAM_960` (not timing_960 alone).

## MP path vs 960×540 product
- MP identity **requires FRAME 1280×720** ($error otherwise) — intentional.
- Product first fit is **ascal-native BEAM_960** 1px @ 20 MHz, not MP 40 Mpix/s path.
- 40 Mpix/s does not claim product 960 geometry without w-scaler map.
