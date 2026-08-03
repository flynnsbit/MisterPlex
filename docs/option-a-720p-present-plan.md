# Option A — ARM decodes 720p → DDR → fabric 720p present only

Product target (rd-duck / parent): **no fabric decode writeback**.
Severed `fs_wr_*` under `DDR_FRAME_STORE` (`present_core.sv:531-596`,
`fs_wr_ready=1` at `:532`) is **accepted** and stays dead for this path.

## Dependency order (present-side only)

### 0. Provenance / mailbox contract (blocks all DDR present)
1. **Know which RBF is loaded** — md5 + promote JSON (see `plxd-discovery-build-stamp.md`).
2. **PLXD live at a discoverable address** — host discovery landed
   (`plxd_discover.hpp` + `FpgaSpi::readBankRelease`). Core must actually
   instantiate `ddr_frame_store` and own the DDRAM port long enough to WE.
3. **Single addressing convention long-term** — prefer absolute `0x3007F128` on
   main **or** doorbell-relative everywhere; dual conventions need discovery
   until w-mem cuts over `mailbox_abi_spec.hpp`.

### 1. Geometry / bank map for 720p payload
4. **Bank capacity** — 1280×720 I420 ≈ 1.38 MiB > legacy 512 KiB bank
   (`ddr_frame_layout_params.svh` Option-C / 720p constants on integ:
   `PHYS 0x30180000`, stride `0x180000`, doorbell `0x3047F000`). Main product
   defaults remain 624×480 canvas (`ddr_frame_layout_params.svh` coded 624×480).
5. **ARM layout writer** must match the core’s bank map (same phys/stride/
   doorbell). Host `ddr_frame_layout.hpp` ↔ RTL params gate already exists;
   extend for the chosen 720p map **with w-mem**.
6. **Doorbell format** — PLXK YUV420p token + bank bit; `STRICT_YUV_DOORBELL`
   path in `ddr_frame_store.sv` must accept the daemon’s format field.

### 2. Present raster / clock (glass side)
7. **Enable L4 path macros only when intentional** — main `Plex.qsf:86-110`:
   `PLEX_PRESENT_720P_L4`, `FRAME_W=1280`/`FRAME_H=720`, optional
   `PRESENT_CLK_PIX_PLL` / `PRESENT_CLK_PIX_74_25` are **default OFF**.
8. **`clk_pix` vs `clk_sys`** — CEA totals need PLL outclk_3 when not using
   sys-clock present; SDC/CDC already staged default-off (clock merge on main).
9. **Content DE / true size** — `present_core` `content_w/h` under
   `PLEX_PRESENT_720P_L4` (`Plex.sv` present instance); mux from delivered
   frame geometry, not fixed 1280 if source is smaller.
10. **Store addressing** — `ddr_frame_store` coded/display/crop/present_x
    must match ARM canvas; pillar/letterbox via `PRESENT_X`/`DISPLAY_*` params
    (`present_core.sv` fstore instantiation `:545-560`).
11. **DE_LAG / edge alignment** — G-VID1 class defects (`present_core` DE vs
    sync lag); re-measure at 720p totals before calling glass clean.

### 3. Scanout correctness under load
12. **Line-fetch bandwidth** — `rd_miss` → black head-of-line
    (`ddr_frame_store` miss path). 720p@24–60 needs proven burst schedule +
    `LINE_COUNT` / want_y policy (`WANT_Y_LINE_ONLY` on integ).
13. **Bus arbiter fairness** — m0 (frame store) vs m1 (bitstream ring): sticky
    `m1_want` must not starve PLXD/mailbox WE (prior arbiter timeout class).
14. **Swap / has_frame multi-frame** — doorbell → `swap_pending` → vsync
    `has_frame`/`disp_bank`/`frames_done` every frame
    (`ddr_frame_store.sv:230-241`), not one-shot.

### 4. Host present path (daemon)
15. **`PRESENT=fpga`** with DDR YUV path (not fb0-only); open FPGA map covering
    banks + doorbell + PLXD candidates.
16. **Publish → doorbell → await PLXD free_mask** using discovery; no silent
    timed overwrite as success.
17. **Idle / logo paint** via same DDR banks so glass never depends on stub
    `fs_wr_*`.

### 5. Explicit non-goals (Option A)
- Fabric `h264_decode_*` in `files.qip` / writeback into `ddr_frame_store`.
- Reviving `decode_stub` → `fs_wr_*` under `DDR_FRAME_STORE`.
- Quartus fit from this lane (parent holds exclusive).

## Exit criteria (parent-measured)
- HDMI shows ARM-updated frames at 720p (or chosen tier), multi-frame change.
- PLXD magic visible at discovered phys; `frames_done` advances.
- `fs_wr_*` remains unused; no colorbars when `has_frame=1`.
