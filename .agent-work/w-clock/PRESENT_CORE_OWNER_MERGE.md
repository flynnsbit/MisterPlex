# present_core.sv — owner merge note (arbitration #3)

**Owner: w-clock.** Non-owners submit patches; never whole-file overwrite.

## Provenance (this tip)

| Feature | Source | Symbols |
|---------|--------|---------|
| B15 film/TV + core cadence Hz | w-clock `0835ddb4`/`1237b171` | `beam_film_class`, `cadence_display_hz`, `present_beam_content_de` |
| B13 runtime DE | w-clock | `content_w/h` → beam `use_rt_geom` |
| Multi-pixel path | w-clock | `PRESENT_MULTI_PIXEL`, `PX_PER_CLK` |
| B7 Option-C 720p params | w-mem `23451699` | `PHYS_BASE_720P`, `HPS_BANK_STRIDE_BYTES_720P`, `DOORBELL_PHYS_720P` |
| B16 live geom + hold black | w-mem `d691d947`/`885ea7ab` | `geom_live_seq`, `geom_live_valid`, `stat_geom_hold_black`, `stat_geom_hollow`, `q5_reserved_reject` |
| Window ports | w-scaler (defaults) | `win_enable`, `content_x0/y0`, `win_h_de/v_de` |

## Store connect policy
- `DDR_FRAME_STORE_RUNTIME_GEOM` **on** → w-mem `ddr_frame_store` pinout (B7+B16).
- **off** (this tree default store) → clock store + `PX_PER_CLK`; B16 stats tied 0.
- Product must merge **w-mem store** + define `DDR_FRAME_STORE_RUNTIME_GEOM` or B7/B16 stay inactive.

## Deliberately NOT taken from w-mem whole-file
- w-mem `display_hz` direct to cadence (reopens HDMI-60 half-rate bug)
- w-mem lack of BEAM_960 / film class

## Plex.sv
Owner w-osd. B15 wiring patch: `patches/Plex.sv.B15_fps_sel.patch.md`.
Canonical nets: **`plxg_*`**.
