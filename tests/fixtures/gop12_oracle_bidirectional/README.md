# Bidirectional color GOP12

Original local procedural artwork under GPL-2.0-or-later; no external media or
PMS bytes. The existing textured color function is translated forwards and then
backwards, to challenge fractional chroma at both horizontal and vertical edges.
An ordinary x264 encode signals square SAR, disabled filtering, one reference,
and baseline P16/skip inter partitions. No source pixels, reference pictures,
coefficients, or expected outputs enter RTL.

`tests/unit/generate_gop12_bidirectional_fixture.py` records the complete
generation/encoding provenance. Intended movement is **not** coverage proof:
the ordinary libavcodec export must demonstrate all sixteen luma qpel phases
and all four luma and chroma interpolation borders. Older fixtures and their
VCL bytes/expected outputs remain unchanged.

```sh
tests/unit/run_gop12_fpga_sim.sh --require-color-motion \
  --fixture tests/fixtures/gop12_oracle_bidirectional/bidirectional_color_sar1_filter_off_320x240_12f.264
```

Coverage cannot excuse missing or mismatching actual RTL Y/U/V. The default
command binds the historical donor; use `--source-pin worktree --au-publish`
only with the source-owned twelve-AU producer extension.
