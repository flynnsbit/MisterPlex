# Textured color / fractional-motion GOP12 oracle fixture

Original procedural test artwork, licensed GPL-2.0-or-later. No third-party
media, PMS capture, donor pixels, or precomputed golden reconstruction.

`tests/unit/generate_gop12_color_fixture.py` creates 320x240 planar YUV420 with
independent smooth colored textures translated across the picture boundaries,
then encodes twelve pictures with ordinary libx264: baseline level 3.0, CAVLC,
one reference, no B pictures, fixed GOP12, P16/skip inter partitions, QP25.
`partitions=none` does **not** exclude I4 or intra macroblocks in P pictures.
Deblocking is not suppressed. Provenance records exact generator, source,
encoded bytes, encoder binary/version, command, and encoder log.

Run the same-bytes composed check:

```sh
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree \
  --fixture tests/fixtures/gop12_oracle_color/textured_color_fractional_320x240_12f.264 \
  --require-color-motion
```

Intended subpixel source motion is **not** proof of encoded fractional vectors.
The ordinary decoder independently exports actual vectors; the gate requires
fractional luma motion, fractional chroma motion, border interpolation support,
and non-neutral/non-flat decoded U/V. The exported vectors are coverage
evidence only and never reach the RTL. All Y/U/V comparison references come
from a fresh ordinary FFmpeg decode of the exact encoded bytes.

This is a local encoder regression, not PMS/profile approval, real-time
throughput, or HDMI evidence. Missing reconstruction or native mismatches must
remain nonzero; no prefilled reference memory or expected-red waiver is allowed.
