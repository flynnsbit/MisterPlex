# Hardware visual decode fixtures

Checked-in inputs for `tests/hw/test_f3_visual_golden.sh`.

- `plex_visual_624x480_1f.264` — one-frame H.264 Baseline/CAVLC Annex-B vector,
  generated from `testsrc2=size=624x480:rate=1` with `cabac=0`, one IDR, no B-slices.
- `plex_visual_640x480_golden.png` — decoded frame presented as the product path should
  display it: coded 624×480, right-cropped to 618×480, then pillarboxed to 640×480 with
  11 black pixels on each side.

The geometry is not defined here. The comparator reads
`host/libmisterplex/ddr_frame_layout.hpp` and
`fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` and refuses to run if they diverge.
