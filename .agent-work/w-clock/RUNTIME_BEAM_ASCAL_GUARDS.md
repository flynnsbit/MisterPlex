# Runtime beam ascal guards (rd-duck)

## Finding (verified)
- `Plex.sv` had `HDMI_BLACKOUT = 0` and `VGA_SCALER = 0` unconditionally.
- `sys_top` wires `HDMI_BLACKOUT` → `hdmi_blackout` → `ascal.swblack`.
- `ascal.vhd` only blackouts when `swblack='1'` **and** input size changes
  (`o_ihsize/=i_hrsize` or `o_ivsize/=i_vrsize`) for 3 frames (`o_newres`).
- With BLACKOUT=0 that path is **disabled**. Do not claim it protects runtime geom.
- `VGA_SCALER` → `vga_force_scaler` ORs into `vga_fb` / `vga_scaler`.
  `direct_video` HDMI raw path is `~vga_fb & direct_video`. SCALER=0 allows
  bypass of ascal for the nonstandard ~16.92 kHz 24/30 beam.

## Fix
Under `PRESENT_BEAM_960`: `VGA_SCALER=1`, `HDMI_BLACKOUT=1`. Legacy else: 0/0.

## Scope honesty
- Blackout = **size only**. Same-size DAR change is NOT covered (ABI#2 note).
- Gate: `tests/unit/test_runtime_beam_ascal_guards.sh` + JSON contract.
