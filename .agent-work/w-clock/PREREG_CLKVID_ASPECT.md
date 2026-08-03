# PRE-REGISTER — clkvid + aspect (pin 842e45c9)

| # | Prediction | Measure |
|---|------------|---------|
| D1 | Recommend (a) clk_sys@24 for L4 product; (b) loses on CDC+L4 mutex | analysis |
| D2 | L4 need 23.993856 MHz; CEA pack 29.7 is MULTI-only | arith |
| A1 | VIDEO_ARX/Y hardcode 4:3 ignores FRAME_W/H | source |
| A2 | After fix, 640x480→4:3, 1280x720→16:9 | test GREEN |
| A3 | Test RED on pre-fix hardcoded 4:3 vs FRAME 1280 | RED rc=1 |
| C1 | CLK_VIDEO always clk_sys even under PRESENT_CLK_PIX_PLL | source |
| C2 | After fix, ifdef routes CLK_VIDEO=clk_pix_pll | source+test |

