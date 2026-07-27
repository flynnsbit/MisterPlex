# On-hardware visual decode regression harness

This harness closes the gap between Verilator decode proof and real DE10-Nano presentation. It uses the shipping
core artifact, pushes a known Baseline/CAVLC bitstream through the existing F3 path, captures the actual HDMI
output, and compares it to a checked-in golden image with quantified pixel metrics.

## Entry points

| Task | Command |
|---|---|
| Scheduled hardware gate | `VISUAL_RBF=/path/to/Plex.rbf VISUAL_FAULT_DEMO=1 tests/hw/test_f3_visual_golden.sh` |
| Known-bad red specimen | `VISUAL_RBF=/path/to/fe7673bc.rbf VISUAL_EXPECT=fail tests/hw/test_f3_visual_golden.sh` |
| Known-good rollback | `VISUAL_RBF=/path/to/57674f2e.rbf VISUAL_EXPECT=pass tests/hw/test_f3_visual_golden.sh` |
| Use already-loaded Plex core | `tests/hw/test_f3_visual_golden.sh` |
| Comparator unit/red-path test | `python3 tests/unit/test_hw_visual_compare.py` |
| Print geometry used by comparator | `python3 scripts/hw_visual_compare.py geometry` |

The hardware script writes artifacts under `build/hw_visual/`: `noise.json`, `compare.json`, `diff.png`,
`status.txt`, captures, and optional `diff_bad_expected_fail.png`.

The capture defaults are intentionally conservative for the current lab dongle:
`VISUAL_CAPTURE_FORMAT=mjpeg`, `VISUAL_CAPTURE_SIZE=1280x720`, `VISUAL_VIDEO_MODE=0`. Use
`VISUAL_CAPTURE_FORMAT=yuyv422` only when the rig proves clean in that mode; corrupted buffers are a harness
failure (`rc=4`), never a core result.

## What is compared

- Input bitstream: `tests/fixtures/hw_visual/plex_visual_624x480_1f.264`.
- Golden: `tests/fixtures/hw_visual/plex_visual_640x480_golden.png`.
- Geometry source of truth:
  - `host/libmisterplex/ddr_frame_layout.hpp`
  - `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh`

The comparator refuses to run if host and RTL constants diverge. It compares the active displayed picture only:
coded **624×480**, display **618×480** after right crop of 6 px, presented **640×480** with **11 px** pillars on
each side. Pillarbox columns are not compared against picture content.

## Metrics and failure artifact

`scripts/hw_visual_compare.py compare` reports:

- active pixel count and exact-match pixel count
- per-plane RGB mean absolute error
- overall MAE
- worst mismatch location in presented and display coordinates
- worst mismatch plane, golden value, captured value, and delta

On failure it emits a PNG with **golden | captured | amplified diff**, so the failure is visually debuggable.

Exit codes are deliberately distinct so a capture-rig failure cannot be mistaken for a red core:

| Code | Meaning |
|---:|---|
| 0 | compare passed |
| 1 | genuine visual mismatch against golden |
| 2 | harness/setup error |
| 3 | stale capture (byte-identical to previous condition) |
| 4 | V4L2/FFmpeg reported corrupted capture buffers/data |
| 5 | capture device absent |
| 6 | capture device busy/exclusive-open |

## Capture noise threshold

The hardware test captures the same static frame five times and derives thresholds from that measured floor:

```text
threshold_mae_rgb = max(1.0, 3 * measured_max_pair_mae_rgb + 1.0)
threshold_max_abs = max(2, 3 * measured_max_abs_noise + 2)
```

Dry-run/unit noise floor from checked-in static frames is exactly zero:

```text
max_pair_mae_rgb = [0, 0, 0], max_abs_noise = 0
threshold_mae_rgb = [1, 1, 1], threshold_max_abs = 2
```

First hardware acceptance run (HDMI MJPEG 1280×720@60, live `57674f2e`, artifacts
`build/hw_visual_accept/`) measured the same zero floor:

```text
max_pair_mae_rgb = [0, 0, 0], max_abs_noise = 0
threshold_mae_rgb = [1, 1, 1], threshold_max_abs = 2
```

The YUYV path on `/dev/video4` repeatedly produced `Dequeued v4l2 buffer contains corrupted data`; the harness
classifies that as `rc=4` and refuses to grade it. MJPEG captures at 1280×720@60 were usable for the current
luma/region comparison, but still retry on occasional decoder invalid-data warnings.

## Red-path proof

`VISUAL_FAULT_DEMO=1` deliberately corrupts one active captured pixel after the green compare and requires the
comparator to fail with a precise location and a diff PNG. This is a harness self-test; a future scheduled window
must also run a known-bad RBF or corrupted F3 input when one is available.

The current characterized hardware red specimen is **`fe7673bc`**: residual telemetry stays green
(`raw[13]=0x14`) but reconstruction signature is `raw[14]=0x00` instead of the simulated `0x3b`, matching a
pred-only/flat-block failure.

Hardware proof on the actual rig:

| Specimen | Result | Evidence |
|---|---|---|
| `57674f2e` known-good | GREEN | `green_compare.json`: exact active pixels `296640/296640`, MAE `[0,0,0]`, max_abs `0`, `rc=0` |
| `fe7673bc` known-bad | RED | `red_compare.json`: exact active pixels `62125/296640`, MAE RGB `[14.3978,51.0105,90.1486]`, max_abs `255`, `rc=1`; diff PNG emitted |

That acceptance used a good hardware capture as the golden and the existing 320×240 baseline F3 vector, because
the checked-in 624×480 fixture did not yet exercise the current rollback RBF reliably. Keep the 624×480 fixture as
the target final gate, but do not claim it as a hardware PASS until its status/visual output is proven.

## Decoder debug output

The harness captures the existing status telemetry in `status.txt` immediately after the F3 push:

```text
sps_valid pps_valid has_idr slice_type mb0 qp res_ok res_tc res_t1 res_dc res_csum recon_sig bytes_in
```

Those fields already expose decoded macroblock/QP/slice/residual/signature state without adding synthesized RTL
scaffolding. For on-screen debug, the safe path is to render these status fields through the existing
`PlaybackOverlay` text compositor from the ARM side after reading status telemetry; do not add test-only RTL.
