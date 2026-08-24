# P4-DISPLAY RCA — live 968b828a still HDMI/VGA 640×480 @ 25.18 MHz 59.9 Hz

**Worker:** W-display-j · **2026-08-13** · **NO FIT.** ZERO Quartus / menu / deploy / RTL edit.
**P4-DISPLAY stays TODO.** Soft-skip ≠ PASS. Chevron ≠ raster PASS.
**FIT_GO=NO** this tick (T7 higher; design named, not implemented).

## Lab (RO)

| | |
|--|--|
| CORE | Plex |
| `/media/fat/_Utility/Plex.rbf` | **`968b828a8ec572bccf43b7bc2d31625a`** (slot720p24j) |
| true480 backup | `Plex.true480.07f54d9f.rbf` intact |
| `[Plex]` + global | **`video_mode=6`** (and ntsc/pal=6) · **`vga_scaler=1`** · `direct_video=0` |
| Saved OSD | `Plex_v9.CFG` `00 60 …` → `status[15:0]=0x6000` → **O[15:14]=01 Display=240p** |
| Live daemon conf | `/media/fat/misterplex/misterplex.conf` **`DISPLAY_RES=240p` `CONTENT_RES=240p` `DECODE=320x240` `OSD_CONTROL=1`** |
| Overlay | **1280×720 0.00KHz 24.0Hz** over **640×480 25.18MHz 59.9Hz** |
| `j.png` | USB request `HDMI_SIZE=1280x720` → file **1280×720** (`/tmp/plex-hdmi-eyes/j.png`). **Not** HDMI PHY proof. |

25.18 MHz / 59.9 Hz is VGA 640×480@59.94 (800×525, 25.175 MHz) = MiSTer **`video_mode=6`**. Repo pin `assets/MiSTer.ini.Plex.required` is still `video_mode=5` (800×600) — lab drifted to 6; either way **ascal**, not L4 clk_pix.

## Three layers (only layer 3 is the glass raster)

```
F12 Display O[15:14]
    → host persist DISPLAY_RES + setDecodeSize (present bank)
    → FPGA display_res_sel wires (dead on beam)
    ✗ does not write /dev/MiSTer_cmd video_mode
    ✗ does not change ascal / VGA_SCALER / 15 kHz vs 31 kHz

L4 720p24 QSF (968b828a)
    → compile-locked beam 1280×720 DE, H_TOTAL=1312 V_TOTAL=762 @ clk_pix 24.0 MHz
    → 24.006 Hz core V.info  (the 1280×720 24.0Hz line)
    ✗ HDMI PHY still ascal(video_mode=6)

ascal + INI  (the 640×480 25.18MHz 59.9Hz line)
    → HDMI = scaler output
    → VGA follows HDMI because vga_scaler=1 (sys_top cfg[2] | VGA_SCALER)
    → Plex.sv assign VGA_SCALER=0 is overridden by INI
```

## Trace (lessons product tree; dirty `main` has no Display)

| Step | Where | What happens |
|------|--------|----------------|
| CONF_STR | `Plex.sv` v9 | `O[15:14],Display resolution,Follow content,240p,480p,720p` |
| Decode | `host/libmisterplex/osd_menu.hpp` | `displayResolutionFromOsdWord`: 0=follow, 1=240p, 2=480p, 3=720p |
| Persist | `arm/misterplexd/main.cpp` | `persistOsdResToConf` writes **`DISPLAY_RES` / `DECODE` / `CONTENT_RES`** only |
| Present bank | `main.cpp` `doPlay` | `setDecodeSize(displayRes.w,h)` — FPGA **bank request**, not raster |
| Mix hang | same `doPlay` | layout ACK fail → retry content size / abort play = **P4-720P-MIX**, not this |
| RTL decode | `Plex.sv` L245–256 | `display_res_sel` → local `content_width/height` |
| Dead wire | same file | those locals are **never consumed**. Geom mux gets `content_res_640x480` (O[5:4]) |
| L4 mux | `plex_present_geom_mux.sv` | **`FABRIC_NATIVE_720P_GEOM` force_native_720p=1** → always 1280×720 |
| Beam | `present_core.sv` L4 | `present_beam_content_de` **compile-locked** 1312×762; `ce_pix=1` on `clk_pix` |
| Product 480p | `Plex.qsf` + `present_beam_true_480p` | 672×496 @ clk_sys/2 = **10 MHz, 30.00 Hz, ~14.88 kHz** — also compile-locked |
| HDMI | `sys_top.v` ascal | programmed from **`MiSTer.ini` `video_mode`**, not O[15:14] |
| switchres | `docs/match-source-hz.md` | **unwired** (P4-HZ DEFER) |

Dirty decode `main`: `O[15:14]=Idle screen`, `osd_menu.hpp` has no `displayResolution`. Live 968b828a is the **lessons `Plex_720p24.qsf`** fork.

## Why 720p24 QSF still emits 640×480 59.9

Not a failed L4 fit. Three independent facts:

1. **Compile-locked core timing ≠ HDMI PHY.** L4 is *ascal-native*: give the scaler a 1280×720@24 capture. `CLK_VIDEO=clk_pix` (24 MHz). HDMI pixel clock is ascal's PLL from `video_mode=6` → **25.18 MHz 59.9 Hz**. 24 Hz beam ≠ 24 Hz HDMI.
2. **MiSTer scaler owns the analog/HDMI standard.** `vga_scaler=1` makes VGA = HDMI. Display never writes `video_mode`. Changing F12 / save / Reset / reboot cannot move 25.18 MHz.
3. **Display does not drive the beam on this RBF.** `display_res_sel` is DCE-dead. `FABRIC_NATIVE_720P_GEOM` pins 1280×720. Saved Display is **240p** and V.info is still **1280×720@24**. Proof the menu is a no-op on raster.

`j.png` 1280×720 is the **UVC dongle request** (`HDMI_USB_EYES.md` / `SLOT720P24I_HDMI_GATE.md`). Same overlay on `ebfe4a12` was already 640×480@59.9.

## P4-720P-MIX — do not conflate

Play hang when Display=720p and content ≠ 720p (spinner; recover 480/480 + Reset) is **host** `setDecodeSize(1280,720)` / PMS 1280×720 into a 640×480 bank / layout ACK. Live conf is **240p/240p**. That bug is not why HDMI is 640×480.

## Next exclusive (named, not this tick)

Prefer **one product core**. Sibling `Plex_720p24.qsf` already is the 720p24 fork. **Do not raise `clk_sys` on `Plex.qsf`.** true480 **`07f54d9f` stays**.

**Do not** re-fit 720p24 to “fix” 640×480 HDMI. 968b828a already has the L4 beam. HDMI is INI ascal.

### Host-only (no exclusive; not a product PASS by itself)

On O[15:14] change, write `/dev/MiSTer_cmd` (lab already did this for sweeps in `docs/crt-lcd-matrix.md`):

| Display | `video_mode` | Notes |
|---------|--------------|--------|
| 240p | custom 15 kHz **or** `direct_video 1` | 240p VGA TV cannot take mode 6 (31.5 kHz) |
| 480p | **6** | today's lab HDMI/VGA |
| 720p LCD | **0** (1280×720@60) | 60 Hz HDMI, not 24 |
| 720p24 native | custom `1280,8,8,16,720,8,6,28,24000` | matches L4 1312×762 @ 24 MHz; **sibling QSF only** |

Persist already writes `DISPLAY_RES`. switchres / P4-HZ stays DEFER.

### RTL exclusive — `P4-DISPLAY-240-480` on **product `Plex.qsf`**

First real step (L55): **240p 15 kHz ↔ 480p** in one RBF.

1. **Wire `display_res_sel` for real.** Delete the dead `content_width/height` locals; feed the beam / `VGA_SCALER`.
2. **`assign VGA_SCALER = (display_res_sel != 2'd0);`** Display=240p → analog = raw core (15 kHz family). 480p/720p → analog follows ascal (lab `vga_scaler=1` already does this from INI).
3. **Runtime beam mux** (not another `ifdef` fork):
   - 240p: colorbars-class NTSC 15 kHz (`H_LAST=637` → 638/line, `V=262`, `ce_pix` /2 @ 20 MHz → **15.67 kHz / ~59.8 Hz**)
   - 480p: keep `present_beam_true_480p` (672×496 @ 10 MHz, 30.00 Hz, ~14.88 kHz) **or** leave 480p as ascal mode 6 + TRUE_480P capture
4. **Do not** enable `PLEX_PRESENT_720P_L4` / `PRESENT_CLK_PIX_PLL` / `FRAME_W=1280` on `Plex.qsf`.
5. 720p glass stays **`Plex_720p24.qsf`** + host custom `video_mode` (or later a clk_pix mux exclusive — not first).

Gates for DONE (not now): MiSTer footer **and** analog/HDMI instrument show 15 kHz 240p vs 31 kHz 480p after F12 Display, save, Reset. Chevron size / `DISPLAY_RES=` upsert / `j.png` 1280×720 **≠** PASS.

## FIT_GO

**NO.** Exclusive is FREE. Design is named (`P4-DISPLAY-240-480`) but not closed as a fit recipe (no freeze md5s, no parent grant). **T7 unique pfps is the higher 720p24 priority.** Parent tick `FIT_GO=NO`.

## Backlog

- **P4-DISPLAY** stay **TODO**
- **P4-720P-MIX** stay **TODO** (different bug)
- **P3-720P24** unchanged (pfps FAIL; 24 Hz beam ≠ 24 unique)

## Evidence

- This card
- `DISPLAY_RES_MUST_CHANGE_RASTER.md` · lessons **L55**
- `/tmp/misterplex-agent-W-display-j.txt`
- Lab RO: `MiSTer.ini` `[Plex] video_mode=6` · `Plex_v9.CFG` · `misterplex.conf` DISPLAY_RES=240p
- `docs/display-resolution.md` (ascal vs content; mode 6 = 640×480@60)
- `fpga/Plex_MiSTer/Plex_720p24.qsf` L4 + `PRESENT_CLK_PIX_24`
- `present_core.sv` L4 identity / `present_beam_true_480p.sv`

No Plex tokens in this file.
