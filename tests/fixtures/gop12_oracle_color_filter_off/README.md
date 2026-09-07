# Legally encoded filter-off color GOP12

GPL-2.0-or-later; derived only from the original procedural artwork in
`../gop12_oracle_color`. This is a **local re-encode**, not captured PMS media.

`tests/unit/encode_gop12_color_filter_off.py` ordinarily decodes the original
color fixture and re-encodes twelve pictures using libx264 baseline level 3.0,
CAVLC, one reference, fixed GOP12, QP25, and `no-deblock=1`. This is a distinct
encoded stream, not a patched header or a different interpretation of the
filter-on fixture. Its encoder-input pixels are never injected into RTL.

The independent oracle uses unchanged ordinary decoder defaults. Header tracing
must report `disable_deblocking_filter_idc=1` for every slice. Adjacent provenance
binds the original stream, generator, output bytes, encoder command/version and
log; the launcher checks its required encoded deblocking flag independently.

```sh
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree --require-color-motion \
  --fixture tests/fixtures/gop12_oracle_color_filter_off/textured_color_fractional_filter_off_320x240_12f.264
```

All native Y/U/V pixels must still match, with all sixteen qpel phase pairs,
fractional chroma and all four border-support cases independently measured.
Passing encoded-filter-off content would not prove filter-on decoding, general
profile support, real-time behavior, PMS operation, presentation or glass.
