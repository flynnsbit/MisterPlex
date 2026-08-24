# N20_FREEZE — unfitted N20_MBOX_ISS_LATCH cone

Permanent-store copy of worktree card
`/home/shawn/Projects/MisterPlex-wt-480p-lessons/Memory/lab/status/N20_FREEZE.md`.
Worker D-n20-freeze. **FREEZE_OK ≠ FIT_GO ≠ BUILD_OK.** unique24=FAIL.
FIT_GO=NO. Did not write `/tmp/misterplex-FIT_GO_N20.parent`.

## md5 table

| Path | full md5 | prefix8 |
|------|----------|---------|
| `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv` | `8ff71759d7b8ffd6634b1ab518b674b4` | `8ff71759` |
| `fpga/Plex_MiSTer/rtl/fabric_ddr_reader_n17.sv` | `532b4dac538a5220b30b9a5ab5347abb` | `532b4dac` |
| `fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv` | NOT_RUN this worker | NOT_RUN |
| `fpga/Plex_MiSTer/Plex_720p24n20.qsf` | `667fd155fbce70642c2569cbca5db78b` | `667fd155` |
| `fpga/Plex_MiSTer/Plex.sv` | `0beb4f38f63cd43be05bff56b4cd9190` | `0beb4f38` |
| `fpga/Plex_MiSTer/rtl/sdram_n7.sv` | `7ccc5777b0cb2d8d935f14a8dfabfb83` | `7ccc5777` |

Live store `8ff71759` ≠ n19 stick freeze `7f3d52c0` ≠ n19 frame-store `0b01ffa8`.
QSF: FABRIC_NO_MOVER=1 PRODUCT_NO_STUB=1 DDR_FRAME_STORE=1 PRESENT_CLK_PIX_24=1; PLEX_CLK_SYS_24 commented.
Scripts exist: `scripts/fit_slot720p24n20.sh` `scripts/play_slot720p24n20.sh` (not created, not run).

Report: `/tmp/misterplex-agent-D-n20-freeze.txt`
