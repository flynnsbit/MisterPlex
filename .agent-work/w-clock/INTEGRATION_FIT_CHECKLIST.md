# Integration fit checklist — multi-pixel present (w-clock)

Parent owns the fit and device test. This is the enable recipe only.

## Default-safe today
QSF must **not** define `PRESENT_MULTI_PIXEL`. Shipping path = 1 ppc Template.

## Enable (one intentional fit)
In `Plex.qsf` / define-parity channel (match Verilator macros):
```
set_global_assignment -name VERILOG_MACRO "PRESENT_MULTI_PIXEL=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_PX_PER_CLK=2"
```
Prefer PPC=2 first (720p24 arithmetic). PPC=4 later for CEA 720p60.

Coordinate with w-scaler / w-mem:
- `FRAME_W`/`FRAME_H` and ddr layout **1280×720** when showing native 720p banks
- At 640×480 the path clamps glass coords (still exercises N-wide + serializer)

## Connected chain (must survive map)
```
present_video_timing_720p (u_mp_timing)
  → present_beam_ppc H_DE=1280 (u_mp_beam)
  → ddr_frame_store.PX_PER_CLK (+ y_q_hi dual-port)
  → rd_r_n/g/b_n → present_npx_path (u_mp_npx_path)
  → r/g/b + H/V sync (when has_frame / use_ext)
```
If map.rpt shows u_mp_beam / u_mp_npx_path / u_mp_timing **removed**, the fit is worthless — stop.

## Video mode honesty
- Active geometry under macro+use_ext: **1280×720 DE**, CEA totals 1650×750.
- Same-clock 20 MHz → fps_eff ≈ **16.16 Hz**, not 24/60. See VIDEO_MODE_720P.md.
- Template H_DE=529 path must remain when macro OFF.

## Parent device checks (not agent)
1. ONE menu deploy of new RBF (beam already `video_mode=0` 1280×720@60 HDMI)
2. Capture via `scripts/hdmi_capture_idle.sh` only (never bare ffmpeg 1-frame)
3. **Control arm (parent, core `d1b24e0c`, ARM idle):**  
   `CYAN_PX=0` · `ACTIVE=923x717` · orange chevron · no cyan  
   File class: parent `/tmp/prereg_control720.txt` (4/4 HIT)
4. **Fabric discriminators (must both move vs control):**
   - Colour: w-osd PASS ⇒ `CYAN_PX>=2000` (`#00C8FF` L-brackets; ARM cannot emit)
   - Geometry: native 1280×720 path ⇒ `ACTIVE` grows toward full 720p raster  
     (control is 480p-class letterboxed). Colour and geometry must **agree**.
5. w-clock mode ON + `use_ext`: core DE 1280×720 (beam); same-clock refresh ~16 Hz  
   until clk_pix — do not claim CEA 24/60 fps from this alone
6. Edge sweep before claiming DE lock (MP_SYNC_LAG=0 uncalibrated)
7. Rollback: baseline `c5382bee`; restore `video_mode=8` from `MiSTer.ini.bak-parent720` if needed

## Explicit non-claims until measured
- DE_LAG / MP_SYNC_LAG
- Fmax with PPC=2/4 wider YUV
- ARM ms removed (expect present/scale bucket ↓ — parent profiles)

## Consolidated clean budget (parent — cite only this)
```
  720p24 deadline .............. 41.667 ms/f
  ARM decode alone ............. 35.94 ms/f   PASS, margin 5.73
  CPU move into bank ........... 14.97 ms/f   STRUCTURAL (~88 MiB/s)
  decode + CPU move ............ 50.9+ ms/f   FAIL — closed question
  decode + verified DMA ........ THE open ARM question (w-path)
  fabric decode ................ endgame
```
**Why 88 MiB/s is a ceiling, not a knob:** bank @ `0x30000000` is outside kernel
System RAM (`mem=511M` / iomem ends `0x1fefffff`). `/dev/mem` is uncached/device
regardless of `O_SYNC`/`--no-sync` (parent: 0/5 pre-reg HIT; no-sync equal/slower).
"Make the copy faster" family is **dead**. Route A zero-copy into bank is **suspect**
until measured (same uncached boundary on ref reads).  
w-clock lane: fabric present/scanout only — does not depend on CPU move rate.
