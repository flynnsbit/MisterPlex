# Route A vs B — 720p glass (w-clock verdict)

## Pre-register → result

| ID | Prediction | Result |
|----|------------|--------|
| P1 | ascal upscales core input to HDMI mode | **HIT** |
| P2 | Core need not be 1280×720 beam | **HIT** |
| P3 | VIDEO_ARX/ARY → pillar window on HDMI | **HIT** |
| P4 | HDMI timing from WIDTH/HEIGHT config | **HIT** |
| P5 | Route B product; Route A unnecessary/blocked | **HIT** |
| P6 | present_content_window ≠ glass upscale | **HIT** (agree w-scaler LOCKED) |

## Parent clock arithmetic (re-derived, awk true)

Native 720p beam @ clk_sys=20 MHz:

| Timing | H×V tot | fps @20 MHz | MHz for 24 | MHz for 30 |
|--------|--------:|------------:|-----------:|-----------:|
| Tight 1344×750 | 1,008,000 | **19.84** | 24.19 | **30.24** |
| 1440×741 | 1,067,040 | 18.74 | — | 32.01 |
| CEA 1650×750 | 1,237,500 | 16.16 | — | 37.13 |
| **Current film 1182×705** | 833,310 | **24.001** | n/a | n/a |
| Current TV 1182×564 | 666,648 | 30.001 | n/a | n/a |

Active rate 1280×720@30 = **27.65 Mpix/s > 20 MHz** even before blanking.
**Route A native 720p@30 beam does not close at 20 MHz.**

## Route A — overclock feasibility (evidence, not hope)

| Artifact | Fmax clk_sys |
|----------|-------------:|
| Stub-in STA `8fdf440f` | **23.46 MHz** |
| Nostub STA `c74c6863` | **32.59 MHz** |

- **30.24 MHz > 23.46** → **HARD FAIL class on stub-in / decode-present product**.
- **30.24 < 32.59** → only *plausible* on empty-of-stub netlist; re-inserting decode
  historically pulls Fmax toward stub. **Not a shipping claim.**
- CDC clk_sys/clk_ddr 30/90 edge family needs STA; PLL bump still **unapplied**.
- Pre-reg if parent ever fits Route A trial: miss if `Fmax_sys < 30.24` or slack<0.

**Route A verdict: not product path for 720p glass.**

## Route B — ascal owns glass 720p (quoted)

### 1. ascal is an up/down framebuffer scaler
`ascal.vhd:16-19`:
```
-- Interpolation
--   Upscaling   : Nearest, Bilinear, Sharp Bilinear, Bicubic, Polyphase
--   Downscaling : Nearest, Bilinear
```
Output format is **arbitrary** (`ascal.vhd:14` "Arbitrary output video format").

### 2. Output raster = HDMI config, not core beam
`sys_top.v` ascal ports:
```
.htotal (WIDTH + HFP + HBP + HS)
.hdisp  (WIDTH)
.vtotal (HEIGHT + VFP + VBP + VS)
.vdisp  (HEIGHT)
.hmin(hmin), .hmax(hmax), .vmin(vmin), .vmax(vmax)
.iauto (1)
```
OSWEEP free-runs on `o_htotal`/`o_vtotal` (prior absorb doc). Core
`H_TOTAL=1182` never becomes HDMI line rate.

### 3. Scale factors from input size → output window
```
i_ohsize <= o_hsize;  -- o_hsize = o_hmax - o_hmin + 1  (ascal ~1902-1903, 1332)
i_hdown  <= (i_hsize > i_ohsize)  -- else upscale path
```
Input `i_hsize` from iauto DE (`i_himax`). Output window from hmin/hmax.

### 4. VIDEO_ARX/ARY → pillars (sys_top ~945-994)
```
wcalc <= hdmi_height * arx / ary;
hcalc <= hdmi_width  * ary / arx;
videow <= min(wcalc, hdmi_width);  videoh <= min(hcalc, hdmi_height);
hmini <= (WIDTH - videow)>>1;   // pillar
hmaxi <= hmini + videow - 1;
```
HDMI **1280×720** integer windows (recomputed):

| DAR | videow×videoh | pillar |
|-----|---------------|-------:|
| 4:3 | 960×720 | 160 |
| 16:9 | 1280×720 | 0 |
| 5:3 | 1200×720 | 40 |

ascal polyphase-scales **content DE** into that window inside 1280×720.

### 5. Core beam stays content-sized (B13)
Current max-tier 960×540@30 = 15.552 Mpix/s ≪ 20 MHz (margin 1.29×).
624×480@30 = 8.986 Mpix/s. **No clk_sys bump required for glass 720p.**

## Division of labour (LOCKED with w-scaler)

Agree with `MisterPlex-wt-scaler/docs/ascal-vs-content-window-division.md`:

| Owner | Role |
|-------|------|
| **w-clock beam** | True content DE @ H=1182, V=564/705; **not** 1280×720 core raster |
| **w-scaler window** | Store addr within DE (identity when DE==content) |
| **w-scaler + q5 DAR** | VIDEO_ARX/ARY pins |
| **sys_top + ascal** | Pillars + polyphase upscale to HDMI 1280×720 |

Fabric NN upscale into 1280×720 core DE is **redundant** with ascal (do not ship).

## Product path (720p glass)

```
PMS direct-play native WxH (CAVLC)
  → DDR bank WxH
  → beam true-DE = WxH (B13), H_TOTAL=1182
  → VIDEO_ARX/ARY from q5 DAR
  → sys_top hmin/hmax three-case window
  → ascal upscale to HDMI WIDTH×HEIGHT (1280×720)
```

## What w-clock will not do

- Force core DE=1280×720 for SD titles
- Apply PLL 30.24 MHz for Route A without parent fit grant + BUILD_OK
- Claim Route A STA pass without Plex.sta.rpt

## Residual risks (honest)

- HDMI mode must actually be 1280×720 in MiSTer video config (parent/device)
- q5 DAR must be wired (collision #8 / B9) — load-bearing for non-stretched SD
- `VIDEO_ARX=0` still selects full window (stretch) — product must not leave 0
- Glass capture UNKNOWN until device returns
