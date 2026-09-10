# Single-RBF native-copy pipeline

Experimental **fixed 20 MHz** FPGA source, based on the physically qualified
`d3e416a4` baseline in `../functional-sys20-hdmi`. This source passed focused
independent review for a physical trial. **The new image is still physically
unqualified:** no timing, measured FPS, clean-audio or playback acceptance is
claimed here. Canonical/shipping code and earlier experiments are unchanged.

## Change

The complete 149-file FPGA source is in `project/fpga/Plex_MiSTer`. Only three
files differ from that baseline:

- `rtl/fpga_video_publish.sv`: one outstanding tagged native read and one
  retained 64-bit DDR word, overlapping byte reads and packing.
- `Plex.sv`: wires the publisher's pipeline parameter.
- `Plex.qsf`: enables `PLEX_NATIVE_COPY_PIPELINE=1`.

The actual baseline native port remains latency 1 / initiation interval 1.
Both diagnostic and macroblock painters, P/reference/deblock support, native
lease fences, DDR/display/status ownership, geometry, AU/VCL limits, clocks and
timing constraints remain unchanged. The companion and PMS are not changed.

## What was measured

At 20 MHz, the actual shared-port full-240 model reduced copy-to-final-write
acceptance from `366543 / 366688 / 366681` to
`246856 / 247159 / 247154` cycles across three pictures: approximately
**5.98 ms less copy time per picture**, not measured FPS.

That run preserved 230,400 painter RGB pixels, 761,760 native RGB samples and
345,600 native I420 bytes. The checker-paced display interval dropped from four
to three model rasters; the checker itself waits about one raster after
feedback, so this does not establish a hardware frame rate.

Publisher, backpressure, bank reuse, seek/reset, original-PTS, error and
diagnostic-painter checks passed. An attempted broader donor IQ runner required
a newer header absent from this baseline; it was not imported. The retained
diagnostic painter was exercised directly instead. No audio repair is proven.

## Existing simulation entry points

Requires Verilator, a C++17 compiler, Make and Bash. The existing launcher uses
`VERILATOR`, an installed OSS CAD Suite, or Verilator on `PATH`.

```sh
cd experimental/single-rbf-native-copy/project
bash tests/unit/test_fpga_video_publish.sh --pipeline
CLOCK_PROFILE=control20 NATIVE_COPY_PIPELINE=1 \
  bash tests/unit/test_ingress_frozen_pair.sh \
  full240-joint joint-filter joint-seek legacy-full240
```

The publisher check generates its inputs without media files. The integrated
checks require the existing `tests/fixtures/feature-full240-3` and
`tests/fixtures/feature-textured-pair` inputs locally. Fixture media, logs,
binaries and build outputs are deliberately not published. Only `control20`
is supported by this isolated publication, despite other inherited runner
selectors. Shared lab use still requires its normal resource guards.

The next gate is a separately owned fit and timing qualification, followed by
real LAN Plex Web cast, HDMI picture and stereo measurement. Do not deploy from
source-review or simulation success alone.

Original per-file copyright/license notices remain authoritative and unchanged.
`licenses/` contains the existing GPL-2.0 and GPL-3.0 texts, including applicable
GPL-3.0-or-later notices. No SDK or vendor simulation libraries are included.
