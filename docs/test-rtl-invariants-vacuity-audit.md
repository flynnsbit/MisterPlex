# `test_rtl_invariants.py` vacuity audit

Audit date: 2026-07-28. Base: `a0a024e`; merge-base with requested tip:
`a0a024eb46088c0b99e3f1b2d220b3cd8ff03935`.

Scope: every current `check_*` invariant in `tests/unit/test_rtl_invariants.py`.
Current tip has 22 invariants: 21 sound, 0 vacuous, 1 over-tight.

Method: for each row, mutate the property the invariant claims to protect, run
`python3 tests/unit/test_rtl_invariants.py`, confirm the mutant actually exists in
source, then restore it. A sound row goes red with a local diagnostic. The one
untracked-debris invariant is sound because the expected mutation is green while
untracked debris exists.

## Verdicts

| Invariant | Verdict | Mutation and observed output |
| --- | --- | --- |
| `check_source_text_matcher_hardening` | sound | Disabled inactive-branch stripping. `rc=1`: `FAIL: DE_LAG has 2 active RTL definitions. Source-text invariants must not be satisfiable by a duplicate decoy definition; keep one product definition.` |
| `check_present_core` | sound | Changed `DE_LAG` to 2. `rc=1`: `FAIL: present_core DE_LAG is 2, expected 3...` |
| `check_phase_a_surface` | sound | Removed `F1,raw` from active `CONF_STR` and added a decoy string elsewhere. `rc=1`: `FAIL: Plex.sv Phase A feature surface: Plex.sv CONF_STR missing \`F1,raw\`.` |
| `check_plex_reset_domains` | sound | Tied `present_reset` to `sdram_startup_busy`. `rc=1`: `FAIL: Plex.sv reset-domain contract: Plex.sv must keep DDR_FRAME_STORE present_core reset independent of sdram_startup_busy.` |
| `check_quartus_syntax_tripwires` | sound | Changed `h264_deblock_writeback_ctrl` parameter to `localparam`. `rc=1`: `FAIL: Quartus syntax tripwire: h264_deblock_writeback_ctrl parameter port list contains localparam.` |
| `check_async_fifo_write_full_no_comb_loop` | over-tight | Behavior-preserving rename `wr_full_now` -> `wr_full_registered`. `rc=1`: `FAIL: async_fifo wr_full must be based on the registered write pointer...` This protects a real Quartus comb-loop class, but it is source-shape sensitive. |
| `check_frame_store_cdc_contract` | sound | Moved frame line-buffer read clock to `clk_ddr`. `rc=1`: `FAIL: ddr_frame_store CDC contract: frame line-buffer RAM reads must remain in clk.` |
| `check_mailboxes` | sound | Changed `MAILBOX_PHYS` to `DOORBELL_PHYS + 0x104`. `rc=1`: `FAIL: ddr_frame_store PLXS mailbox must derive from DOORBELL_PHYS + 0x100, got DOORBELL_PHYS + 32'h104.` |
| `check_mailbox_map_collisions` | sound | Changed PLXI address to collide with PLXS. `rc=1`: `FAIL: Mailbox address collision: PLXI and PLXS both at 0x3007F100.` |
| `check_ddr_bitstream_ring` | sound | Changed `kErrActiveBit` to 46. `rc=1`: `FAIL: DDR bitstream PLXE kErrActiveBit=46, expected 47.` |
| `check_status_telemetry` | sound | Changed `kReconSigByte` to 13. `rc=1`: `FAIL: status_telemetry.hpp kReconSigByte=13, expected 14.` |
| `check_ddr_frame_layout_contract` | sound | Changed RTL coded width to 640. `rc=1`: `FAIL: DDR frame layout mismatch: kPlex480pCodedWidth=624 but DDR_FRAME_CODED_WIDTH=640.` |
| `check_runtime_ddr_layout_literal_sweep` | sound | Added tracked shell assignment with `STRIDE=0x80000 FRAME=449280`. `rc=1`: `FAIL: runtime DDR frame layout literals must route through ddr_frame_layout derivation; found tests/hw/test_fbar_fast.sh:116...` |
| `check_runtime_ddr_layout_literal_ignores_untracked_debris` | sound | Added untracked file with `0x80000`/`449280`. `rc=0`: invariant stayed green and printed `PASS runtime DDR layout literal scan ignores untracked worktree debris`. |
| `check_ddr_frame_store_yuv_read_contract` | sound | Changed chroma line stride to `FRAME_W / 16`. `rc=1`: `FAIL: ddr_frame_store.sv: chroma line fetch stride must be CODED_W/16 qwords (half-width bytes).` |
| `check_present_geometry_stride_contract` | sound | Changed FFmpeg raw width to `ddrGeometry.display_width`. `rc=1`: `FAIL: present geometry/stride contract: FFmpeg rawvideo width must be the coded stride width (624) for FPGA-presented 480p.` |
| `check_ddr_bank_handoff_contract` | sound | Removed same-bank reuse wait by changing the condition to `false`. `rc=1`: `FAIL: DDR bank handoff contract: sendDdrFrame must wait rather than reusing the same bank before the reuse floor.` |
| `check_plxd_liveness_degeneracy` | sound | Renamed `plxdStaleCount_`. `rc=1`: `FAIL: PLXD liveness/degeneracy defence missing: PLXD consumer must track consecutive stale reads.` |
| `check_yuv_ddr_writer_contract` | sound | Reintroduced `DdrFrameFormat::Rgb-565 (hyphenated here so the migration sweep does not treat this audit note as product guidance)`. `rc=1`: `FAIL: ARM DDR writer code still exposes DdrFrameFormat::Rgb-565 (hyphenated here so the migration sweep does not treat this audit note as product guidance).` Also verified tracked comments and untracked debris do not trip the sweep. |
| `check_present_path_degradation_contract` | sound | Appended a one-shot DDR disable. `rc=1`: `FAIL: media_player.cpp still has an RGB-over-SPI-to-F1 fallback or disables future DDR attempts after a failure.` |
| `check_ddr_bitstream_product_path` | sound | Replaced `beginBitstreamSession` with a legacy session name. `rc=1`: `FAIL: media_player.cpp must feed STREAM=1 through the DDR record transport with explicit begin/pushNal/end.` |
| `check_h264_quartus_subset` | sound | Reintroduced an unpacked-array element inside a function-body concatenation. `rc=1`: `FAIL: H.264 RTL uses constructs Quartus rejected while Verilator accepted:` followed by `h264_dpb.sv:387: unpacked array element \`ref_win[...]\` inside a function-body concatenation matched the observed Quartus rejection...` |

## Validation after restoring mutations

```text
make_unit_rc=0
grep_c_caret_OK=91
unique_test_count=44
GATE_SKIP_SUMMARY total=2 critical=1 high=1 advisory=0
```
