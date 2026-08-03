# Product ascal path guards (rd-duck CONFIG BLOCKER)

## Finding (MEASURED)
- `sys_top.v`: `vga_fb = cfg[12] | vga_force_scaler`, `direct_video = cfg[10]`
- HDMI raw mux: `(~vga_fb & direct_video) ? hdmi_dv_* : hdmi_*_osd` (ascal path)
- `emu.VGA_SCALER` → `vga_force_scaler` (sys_top ~1807)
- With `VGA_SCALER=0` and MiSTer Direct Video on: **ascal bypassed**; core raster
  (BEAM ~1182 clocks / ~16.92 kHz @24/30) goes to the sink. **720p glass absent.**
- Prior fix gated `VGA_SCALER=1` only under `PRESENT_BEAM_960`; legacy/`else` = 0.
  Product fits without that define (w-mem inheritance) still hit the blocker.
- Source-level ascal `iauto` proof is **irrelevant** on the bypass mux.

## Fix (this branch)
```systemverilog
assign VGA_SCALER    = 1;  // product always
assign HDMI_BLACKOUT = 1;  // size-only swblack
```
Direct Video raw is **unsupported** for this core (force-scaler makes mux inert).

## Scope honesty
- Blackout = **size only** (not DAR-only, not B20 hold).
- Gate: `tests/unit/test_runtime_beam_ascal_guards.sh`
- JSON: `assets/runtime_beam_ascal_guards.json`

## Ladder
| Module | note |
|--------|------|
| Plex.sv | ON_MAIN=no until merge; ENABLED=yes (unconditional assigns) |
| sys_top.v | stock MiSTer wiring; not modified |
