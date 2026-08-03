# Route A/B 720p — PRE-REGISTERED predictions (before ascal deep read)

Timestamp: before reading ascal scale path / ARX-ARY for this task.

| ID | Prediction | Conf |
|----|------------|------|
| P1 | ascal **upscales** core input to configured HDMI output timing (`o_htotal/o_hdisp/...` from video mode), independent of input ih×iv | high |
| P2 | Core beam need not be 1280×720; content-sized true-DE is the intended input | high |
| P3 | `VIDEO_ARX`/`VIDEO_ARY` (or ascal hmin/hmax/vmin/vmax window) drive pillarbox/letterbox in the **output** window, not by changing core H_TOTAL | medium-high |
| P4 | Product already runs HDMI at 1280×720 class via sys_top video config while core was 624/960 class historically | medium |
| P5 | Route B is the product path; Route A (clk_sys≥30.24 for native 720p@30) is unnecessary for glass 720p and blocked by stub Fmax 23.46 | medium-high |
| P6 | w-scaler `present_content_window` is still load-bearing for **input** window/crop before ascal, not redundant with ascal output AR | medium |

Miss policy: quote contradictory RTL; flip route recommendation; no invented STA.
