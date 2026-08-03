# w-clock STATUS — clkvid + aspect @ 842e45c9

**branch:** w-clock-clkvid-aspect  
**tip:** see git  
**gates:** rtl-lint rc=0; unit rc=0; SKIP-NOT-PASS=2

## Decision: (a) clk_sys→24 for L4
L4 1312×762 needs 23.993856 MHz. CEA 29.7 is MULTI-only (⊥ L4). Zero new CDC.

## Applied
- CLK_VIDEO ← clk_pix_pll under PRESENT_CLK_PIX_PLL
- VIDEO_AR ← FRAME_W:FRAME_H (720p→16:9 when FRAME 1280x720)
- inventory + aspect RED/GREEN tests

## Not applied
- PLL 24 MHz enable (inventory first; parent fit HELD)
