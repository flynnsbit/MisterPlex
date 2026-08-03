# Hardcoded geometry/cadence audit (w-clock files)

Classification after runtime-DE + ABI#2 pivot.

| Location | Value | Class | Action |
|----------|-------|-------|--------|
| `present_beam_content_de` params H_DE/V_ACTIVE 960/540 | max-tier defaults | **deliberate-still-correct** | OK — runtime overrides via rt_* |
| `present_beam_content_de` H_TOTAL=1182 | fixed line class | **deliberate-still-correct** | OK — constant f_h design |
| `present_beam_content_de` V_TOTAL=564 | TV default param | **deliberate-still-correct** | film via rt_vtotal=705 |
| `present_core` beam_htot_req=1182 | fixed | **deliberate-still-correct** | OK |
| `present_core` beam_vtot_req from content_fps | runtime | **fixed (B15)** | was hardwired 24 — now q5 |
| `present_core` 0→960×540 fallback | idle max tier | **deliberate-still-correct** | OK when content_w/h=0 |
| `present_core` FRAME_W/H must 960×540 | bank max | **deliberate-still-correct** | storage max tier |
| `plex_content_fps_sel` unspecified→24 | conservative | **deliberate-still-correct** | ABI#2; not invent 30 |
| `Plex.sv` content_width 320/640 ladder | OSD until PLXG | **deliberate-but-now-wrong** for product DE | staged; PLXG mux merge supersedes |
| `Plex.sv` plxg_fps_valid=0 staged | until w-mem q5 | **deliberate-temporary** | wire on merge |
| `FAULT_*` hardwire 24 | red twins | **deliberate-test-only** | OK |
| `present_video_timing_960` 960/540/1182/564 | math pack | **deliberate-still-correct** | not a beam |
| colorbars / MULTI_PIXEL paths | legacy | out of BEAM_960 first fit | leave |

### Pre-empt (same class as content_fps=24 / VIDEO_ARX=0)
Anything that **freezes** a value the daemon now knows is a future defect:
- content_fps hardwire — fixed B15/ABI#2
- Plex ladder content_w/h — fixed when w-mem mux wired (collision #5)
- plxg_fps_valid staged 0 — fixed when w-mem q5 lands
