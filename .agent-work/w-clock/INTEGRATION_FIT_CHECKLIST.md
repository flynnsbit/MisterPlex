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
1. ONE menu deploy of new RBF
2. Idle still paints (daemon) — may differ canvas if profile 480p
3. With a frame in bank: no sustained black; capture via `scripts/hdmi_capture_idle.sh`
4. Edge sweep before claiming DE lock (MP_SYNC_LAG=0 uncalibrated)
5. Rollback: baseline `c5382bee` / prior good RBF

## Explicit non-claims until measured
- DE_LAG / MP_SYNC_LAG
- Fmax with PPC=2/4 wider YUV
- ARM ms removed (expect present/scale bucket ↓ — parent profiles)

## Parent decode evidence (clean re-measure; contaminated session WITHDRAWN)
Parent killed a rogue on-device CPU burner that polluted prior sweeps.
**Clean (exit=0):** decode alone **35.94 ms/f** mean (35.82/36.05) vs 41.667 → **+5.73 ms** margin.
Any concurrent ARM-side peer tested so far still pushes past the deadline.
Route A (decode under verified full-frame DMA) is **unmeasured** — prior DMA/pl330 and
"CPU-theft dominated" claims are **retracted**. Fabric planes remain mandatory for 720p.
Do not cite bank-sweep / serial-copy-anomaly numbers from the contaminated window.
