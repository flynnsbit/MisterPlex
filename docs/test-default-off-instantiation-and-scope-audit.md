# Default-off instantiation and scope vacuity audit (W-GATE)

Audit date: 2026-07-28. Branch: `w-gate-inst-vacuity` after merging
`origin/w-decode-real-intra` and `origin/w-deblock`.

## Raw instantiation numbers

The preprocessor-aware gate changed the measured product graph. Measurement wins:
the older source-text graph counted inactive `DDR_FRAME_STORE` `else` branches as
reachable. With checked-in QSF macros, the real default product graph is:

```text
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 default_reachable=41 nondefault_config_reachable=6 bench_only=21 config_reachable=41
```

`DECODE_REAL_INTRA=0` vs `DECODE_REAL_INTRA=1`:

```text
DECODE_REAL_INTRA=0_COUNT 41
DECODE_REAL_INTRA=1_COUNT 29
DECODE_REAL_INTRA_ON_ONLY_COUNT 3
DECODE_REAL_INTRA_ON_ONLY h264_decode_top
DECODE_REAL_INTRA_ON_ONLY h264_intra16x16_pred
DECODE_REAL_INTRA_ON_ONLY h264_intra4x4_pred
DECODE_REAL_INTRA_OFF_ONLY_COUNT 15
DECODE_REAL_INTRA_OFF_ONLY decode_stub
DECODE_REAL_INTRA_OFF_ONLY h264_chroma_epel_block_8x8
DECODE_REAL_INTRA_OFF_ONLY h264_chroma_epel_sample
DECODE_REAL_INTRA_OFF_ONLY h264_deblock_writeback_ctrl
DECODE_REAL_INTRA_OFF_ONLY h264_dpb_i420_addr
DECODE_REAL_INTRA_OFF_ONLY h264_dpb_mb_write_addr
DECODE_REAL_INTRA_OFF_ONLY h264_dpb_one_ref
DECODE_REAL_INTRA_OFF_ONLY h264_inter_mc_16x16
DECODE_REAL_INTRA_OFF_ONLY h264_inter_mc_part
DECODE_REAL_INTRA_OFF_ONLY h264_luma_qpel_block_16x16
DECODE_REAL_INTRA_OFF_ONLY h264_luma_qpel_sample
DECODE_REAL_INTRA_OFF_ONLY h264_luma_ref_tap_addr
DECODE_REAL_INTRA_OFF_ONLY h264_mv_pred_16x16
DECODE_REAL_INTRA_OFF_ONLY h264_mv_pred_part
DECODE_REAL_INTRA_OFF_ONLY h264_ref_clamp
INTRA4_REACH_OFF False
INTRA4_REACH_ON True
INTRA16_REACH_OFF False
INTRA16_REACH_ON True
```

Conclusion from the numbers only: `h264_intra4x4_pred` and
`h264_intra16x16_pred` do become reachable when `DECODE_REAL_INTRA=1`; they are
absent from the default product graph.

## Gate extension

Category name: `NONDEFAULT_CONFIG_REACHABLE`. The gate also prints
`DEFAULT_OFF_DEFINE_REACHABLE_MODULE` for the subset reached by flipping a
checked-in default-off macro on.

Current non-default category:

```text
NONDEFAULT_CONFIG_REACHABLE_MODULE ddram_frame_rd defines=DDR_FRAME_STORE=<undefined>
NONDEFAULT_CONFIG_REACHABLE_MODULE frame_store defines=DDR_FRAME_STORE=<undefined>
DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_decode_top defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_intra16x16_pred defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_intra4x4_pred defines=DECODE_REAL_INTRA=1
NONDEFAULT_CONFIG_REACHABLE_MODULE sdram_memtest defines=DDR_FRAME_STORE=<undefined>
```

Red/green proof:

```text
NONDEFAULT_MISSING_DECL_RED_RC 1
NONDEFAULT_CONFIG_REACHABLE_UNDECLARED h264_intra4x4_pred defines=DECODE_REAL_INTRA=1
GENUINE_REACHABLE_FALSE_CATEGORY_RED_RC 1
RTL_MODULE_INSTANTIATION_FAIL: NONDEFAULT_CONFIG_REACHABLE modules are now default product-reachable; remove the declaration: decode_stub
NONDEFAULT_RESTORE_GREEN_RC 0
```

Literal comparison: default-reachable module set from `emu` under QSF macros vs
RTL declarations, plus non-default reachable deltas from macro variants listed
in `rtl/nondefault_config_modules.txt` and bench-only declarations in
`rtl/bench_only_modules.txt`.

Does not cover: post-fit retention, meaningful dataflow, or whether enabling a
non-default macro is fit-safe. It only prevents "declared in tree" from being
mistaken for "in the default product."

## W-SWAP livelock gate

Raw run:

```text
SWAP_GATE_RC=0
Raw: final assertion operands top.frames_done=4 frames_before_third_plus_one=3 swap_pending=0 pending_ready=0
OK ddr_frame_store swap-livelock natural: third doorbell swapped without injection
Raw: final assertion operands top.frames_done=2 frames_before_third_plus_one=3 swap_pending=1 pending_ready=0
OK ddr_frame_store swap-livelock red-check: prep invalid-only fault failed naturally
SWAP_SKIP_RC=77
```

Literal comparison: after the third natural doorbell, `top.frames_done` must be
at least `frames_before_third + 1`. The red build injects
`DDR_FRAME_STORE_FAULT_PREP_INVALID_ONLY` and requires the natural `no third
swap` diagnostic.

Vacuity mutation:

```text
SWAP_VACUOUS_TRACE_RED_RC 1
FAIL ddr_frame_store swap-livelock red-check: prep invalid-only fault unexpectedly passed
SWAP_RESTORE_GREEN_RC 0
```

Verdict: sound for the claimed livelock property. It does not cover pixel color
correctness, ARM timeout timing, or hardware/Quartus behaviour.

## W-DEBLOCK bS=4 scope gates

Raw runs:

```text
DEBLOCK_GATE_RC=0
Scope: filtered_samples=641 luma_bS4=16 chroma_bS4=4 real_fixture_qp_range=25..25 synthetic_qp_range=4..51
STREAM_DEBLOCK_GATE_RC=0
Scope: filtered_samples=128 real_fixture_filtered_samples=4 luma_bS4=120 chroma_bS4=4 real_fixture_qp_range=25..25 synthetic_qp_range=4..51
DEBLOCK_SKIP_RC=77
STREAM_DEBLOCK_SKIP_RC=77
```

Literal comparisons:

- `h264_deblock_tb.cpp`: `scopeFilteredSamples`, `scopeLumaBs4`, and
  `scopeChromaBs4` must all be `> 0`.
- `stream_path_deblock_tb.cpp`: `scopeFilteredSamples`,
  `scopeRealFixtureModified`, `scopeLumaBs4`, and `scopeChromaBs4` must all be
  `> 0`.

Red/green mutations:

```text
DEBLOCK_SCOPE_ZERO_RED_RC 1
FAIL h264_deblock RTL sim: Scope: filtered_samples=637 luma_bS4=16 chroma_bS4=0 (bS=4/chroma must modify at least one sample)
DEBLOCK_SCOPE_RESTORE_GREEN_RC 0
STREAM_DEBLOCK_SCOPE_ZERO_RED_RC 1
FAIL stream_path deblock integration: Scope: filtered_samples=124 real_fixture=4 luma_bS4=120 chroma_bS4=0 (bS=4/chroma/real fixture must modify samples)
STREAM_DEBLOCK_SCOPE_RESTORE_GREEN_RC 0
```

Verdict: nonzero scope cannot be satisfied by `Scope: 0` in these two gates. The
scope checks do not prove full-frame visual quality or all deblock edge classes;
they prove the named luma bS=4, chroma bS=4, and real-fixture paths actually
modify samples before PASS.
