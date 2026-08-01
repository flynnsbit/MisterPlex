# Parent status — output-raster overlay bug (w-osd-hires)

**Branch tip:** see `git -C .worktrees/w-osd-hires rev-parse --short HEAD`  
**Live device:** parent reports md5 `36b89bcb` still `canvas=624x480` — **none of this branch’s overlay ARM has been deployed.** That log is expected on main/live.

## 1. What landed (code, not silicon)

| SHA (lineage) | What |
|---|---|
| `8475a8dd` | Opaque panel + title (black-rect software fix) |
| `ed1fc22f`…`4ed6a096` | Sticky PAUSED, readback hardening |
| `1c531e3f` | Feasibility: only (c) meets user wording |
| `ada7af1f` | Area-budgeted (c) design + G0 layout gate |
| *(this commit)* | `mister_video_mode.hpp`, dual log `output=`, native-score tool |

**Not live / not started:** RTL `plex_chrome`, Quartus fit, changing bank `canvas=` to HDMI size (impossible on F1 path — see §2).

**Deployable ARM now:** black-rect + sticky pause + logs. **Does not fix low-res.**

## 2. What decides `canvas=` (quoted)

`paintIdle` / `publishPausedOverlayFrame`:

```cpp
const DdrFrameGeometry g = plex480pDdrFrameGeometry();
const int cw = g.coded_width.get();   // 624
const int ch = g.coded_height.get();  // 480
// ...
log("media: idle overlay canvas=" + … cw … "x" … ch …);
overlay_.renderRgb24(rgb.data(), cw, ch);  // or renderYuv420p
```

`plex480pDdrFrameGeometry()` → coded **624×480** (`ddr_frame_layout.hpp`).  
That is the **DDR/DECODE bank**, then `ascal` → `video_mode` (device **12 = 1920×1440**).

**What it must become for the user bug:** authoring / composite at **output W×H** *after* scale — not a larger F1 buffer. Design: `docs/osd-chrome-plane-design.md` (display-list post-ascal). Log will show `plane=1` when that ships; today `plane=0`.

New dual log (this branch, after deploy):

```text
media: idle overlay canvas=624x480 font=12x16 scale=2 chrome=1 output=1920x1440 mode=12 plane=0
```

`canvas=` stays bank until RTL; `output=` is resolved from `/media/fat/MiSTer.ini` `[Plex] video_mode`.

## 3. Resolution independence

`computeOutputChromeLayout(outW,outH)` / G0:
`bodyScale = clamp(2..8, round(H/240))` → 1440→6, 480→2, 240→2; panel in-bounds for 800×600, 640×480, 320×240.

## 4. Font + CPU

| Approach | Sharp at 1440? | CPU note |
|---|---|---|
| 12×16@2 in bank (today) | **No** (3× stretch) | Already paid in paintIdle |
| bodyScale=3 in bank | Larger mush | Extra fill cost, **not** the fix |
| ARM paint full 1920×1440 RGB every show | Would need plane + huge fill | **Reject** at 86% system busy |
| **Display-list → RTL rasterize (c)** | **Yes** | ARM: O(n glyphs) list build **≪1% core** once per UI event; RTL blends at pixel clock |

**Budget:** list build target **<0.5 ms** / show on Cortex-A9; **0 steady-state %** when chrome hidden. No per-frame software composite during playback.

## 5. Capture acceptance (parent runs)

```bash
# RED baseline (today’s bug) — must FAIL pitch:
python3 tools/score_overlay_output_native.py --selftest; echo "true rc=$?"
# expect true rc=0 on selftest (meaning: archive correctly fails native)

# After pause on device, grab HDMI then:
python3 tools/score_overlay_output_native.py /path/to/grab.png; echo "true rc=$?"
# TODAY expect true rc=1 PRODUCT_NATIVE=FAIL
# AFTER plane expect true rc=0 pitch_ok=True
```

Discriminant: **lattice pitch mode in {3..6}** = bank upscale; output-native clears it (`tools/measure_overlay_edge.py`).  
Archive `osd_pause_3883f5ab_PAUSED_PASS.png`: measured `v_mode_ge2=4 pitch_ok=False VERDICT=FAIL`.

Grabber 1280×720 or 1920×1080@30 OK — **do not** nearest-downsample before score.

## 6. Honest bottom line

User bug is **open**. Software alone cannot place sharp chrome at HDMI resolution on `PRESENT=fpga`. Next product step: **fit grant for (c)** after area solo-map ≤40 M10K. Black-rect remains the only user-visible ARM fix ready to score on deploy.
