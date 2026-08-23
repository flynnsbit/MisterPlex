# SD-family clocks: 15.6 kHz analog vs ≥31 kHz HDMI LCD

HDMI LCD scoring must not poke ascal `video_mode` below **31 kHz** H-rate.
`clk_sys` is a different clock. 24 Hz HDMI is banned. 720p is parked.

## Analog / ascal line rate (not fabric)

`video_mode=hact,hfp,hs,hbp,vact,vfp,vs,vbp,Fpix_kHz`. H-rate = `Fpix / Htot`.

| Label | Cmd Fpix | Htot × Vtot | H-rate | Use |
|-------|----------|-------------|--------|-----|
| **240p CRT** | 6500 kHz | 416 × 262 | **15.625 kHz** / ~59.6 Hz | RGB CRT TV. `kVideoModeCmd240p`. Not HDMI-safe. |
| **480i CRT** | 13500 kHz | 858 × 262 field | **15.734 kHz** / ~60.05 field | NTSC weave. `kVideoModeCmd480i`. CRT-only. |
| **240p LCD** | 25175 kHz | 800 × 525 | **~31.47 kHz** / 59.94 Hz | VESA 640×480@60 ascal preset 6. HDMI LCD floor. |
| **480p LCD** | 40000 kHz | 1056 × 628 | **~37.88 kHz** / ~60.3 Hz | VESA 800×600@60 ascal preset 5. HDMI LCD default. |
| 720p60 (parked) | 74250 kHz | 1650 × 750 | 45.00 kHz / 60 Hz | CEA. Not this campaign. |
| 720p24 (banned) | 30000 kHz | 1650 × 758 | ~18.18 kHz / 24 Hz | TVs will not lock. |

480i is one **262-line field** at 13.5 MHz (BT.601 858), not progressive 480p.
ascal 15 kHz `video_mode` is **RED** on HDMI LCD.

## HDMI LCD scoring

Display label **240p** on an HDMI-LCD scoring path must **not** emit `kVideoModeCmd240p`.
It maps to `kVideoModeCmd240pLcd` (640×480@60). **480i cmd is CRT-only** (no HDMI poke).
Stay at ≥31 kHz ascal: **800×600@60** or **640×480@60**.

OSD Display `O[15:14]` is bank/label, not analog line rate. Latch is reset-only
(`displayRasterApplyOnOsdChange()==false`).

## clk_sys (fabric) vs pixel clock

| Clock | Typical | Domain |
|-------|---------|--------|
| `clk_sys` | 20.000 MHz (product PLL out0); 24.000 MHz if `PLEX_CLK_SYS_24` | Present/decode fabric. STA Fmax is this clock. |
| `clk_ddr` | 90.000 MHz (PLL out2) | HPS DDR. Related-edge to `clk_sys` (same PLL). |
| ascal / HDMI Fpix | 6.5 / 13.5 / 25.175 / 40 / 74.25 MHz | Main `video_mode`. Independent of `clk_sys`. |

15.6 kHz is analog H-rate (`Fpix/Htot`), not a fabric clock. Do not retune
`clk_sys` to “make 240p.” HDMI LCD ascal stays ≥31 kHz regardless of content 240p.

Policy: `videoModeCmdForScoringPath(label, DisplaySink::HdmiLcd)` in
`host/libmisterplex/display_raster.hpp`.

## Analog mux `ce_pix` (clock-enable, not a generated clock)

Template analog raster (`analog_raster_mux` → `colorbars`) runs entirely on
`clk_sys`. `ce_pix` is a **registered clock-enable** (`always @(posedge clk)` +
`if (ce_pix)`). Nothing in this path is `posedge ce_pix`.

| `analog_sel` | `ce_pix` | Pixel step | H clocks | H-rate @ 20.000 MHz |
|--------------|----------|------------|----------|---------------------|
| 0 = 240p | toggle | 10 MHz | 1276 = 638×2 | **15674 Hz** |
| 1 = 480p | held 1 | 20 MHz | 638 | **31348 Hz** |
| 2 = 480i | toggle | 10 MHz | 1276 | **15674 Hz** + `VGA_F1` |

Do **not** `create_generated_clock` on `ce_pix` or analog `HSync`. Do **not**
`derive_clocks`. A future sole fit must keep STA Fmax on `general[0]` 20.000 MHz
and must not invent a 15.6 kHz fabric clock. Silent multicycle-2 on `ce_pix`-gated
paths is also banned: `HBlank`/`HSync` sample every `clk_sys` tick.

SDC: `fpga/Plex_MiSTer/Plex_analog_mux.sdc` (product, `files.qip`). Optional
`Plex_clk_pix.sdc` is a different, default-OFF PLL out3 domain.

## analog_sel CDC (reset-latch, not live F12)

`analog_sel` comes from OSD Display `O[15:14]` (`status[15:14]`) and, later, a
possible HPS doorbell. **Reset-latch only** (`displayRasterApplyOnOsdChange()==false`;
`sel_lat` in the mux loads on `reset`, not `frame_start`). SDC false-paths **to**
`sel_lat` so STA does not treat F12 hops as per-line data. Do not false-path
**from** `sel_lat` (the scandouble → `ce_pix` mux is a real `clk_sys` path).

Future doorbell: 2FF into `clk_sys`, snapshot at reset into `analog_sel` /
`sel_lat`. Do not turn the doorbell into a generated clock.

HDMI LCD refuse of ascal 15 kHz is unchanged (`test_hdmi_lcd_refuse_15k`).
