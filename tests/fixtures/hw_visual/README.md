# Hardware visual decode fixtures

Checked-in inputs for `tests/hw/test_f3_visual_golden.sh`.

- `plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png` — **default gate
  golden**, captured from known-good rollback `57674f2e4c11551898275e99bd4c3067`
  through the repaired `/dev/video4` MJPEG 1280×720@60 path after pushing
  `tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264`. The default
  hardware gate compares only ROI `11,0,160,120` because pixels outside the stable
  decoded top-left region can vary after core reloads on this rollback RBF.
  The visual harness now requires explicit colour provenance; this default gate is
  declared as BT.601/full-range to match the product YUV→RGB path.
- `plex_visual_624x480_1f.264` — one-frame H.264 Baseline/CAVLC Annex-B vector,
  generated from `testsrc2=size=624x480:rate=1` with `cabac=0`, one IDR, no B-slices.
  This is a future target fixture, not the default hardware gate, because it has
  not yet been proven green on rollback `57674f2e`.
- `plex_visual_640x480_golden.png` — decoded frame presented as the product path should
  display it: coded 624×480, right-cropped to 618×480, then pillarboxed to 640×480 with
  11 black pixels on each side. This pairs with the 624×480 target fixture and is
  not used by the default gate.
- `capture_logs/wcap_fe7673bc_yuyv422*.log` — real W-CAP hardware logs from `/dev/video4`
  YUYV422 captures of the characterized bad `fe7673bc959f37fd7da44e8a865f7db3` core.
  They contain V4L2 corrupted buffer diagnostics and are unit fixtures for rc=4
  capture-integrity rejection. The primary log negotiated `yuyv422, 1280x720, 10 fps`
  and reported `1843200 bytes` corrupt (`1280*720*2`); the secondary 640×480 log
  reported `614400 bytes` corrupt (`640*480*2`).

The geometry is not defined here. The comparator reads
`host/libmisterplex/ddr_frame_layout.hpp` and
`fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` and refuses to run if they diverge.
