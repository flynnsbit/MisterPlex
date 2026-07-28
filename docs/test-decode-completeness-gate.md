# Decode completeness gate audit (W-GATE)

Audit date: 2026-07-28. Branch: `w-gate-inst-vacuity`.

## Raw results first

`python3 scripts/check_decode_completeness.py` prints `Scope:` first and returns
rc=1 on the current tree:

```text
Scope: decode-completeness product_configs=DECODE_REAL_INTRA=0,DECODE_REAL_INTRA=1 required_categories=7 manifest=fpga/Plex_MiSTer/rtl/decode_capability_modules.txt
DECODE_COMPLETENESS_CONFIG config=DECODE_REAL_INTRA=0 status=FAIL reachable=41 decode_roots=decode_stub missing_categories=bitstream_entropy,residual_dequant_transform,intra_prediction,deblocking_writeback
DECODE_COMPLETENESS_CONFIG config=DECODE_REAL_INTRA=1 status=FAIL reachable=29 decode_roots=h264_decode_top missing_categories=bitstream_entropy,residual_dequant_transform,intra_prediction,inter_prediction_mc_subpel,mv_prediction,dpb_reference_management,deblocking_writeback
DECODE_LINEAGE_COUNT count=4
```

Category detail:

```text
DECODE_REAL_INTRA=0
  PASS inter_prediction_mc_subpel
  PASS mv_prediction
  PASS dpb_reference_management
  FAIL bitstream_entropy: missing h264_rbsp_filter,h264_baseline_syntax_parser,h264_exp_golomb_reader,h264_p_mb_type_decode
  FAIL residual_dequant_transform: present h264_dequant4x4,h264_idct4x4,h264_recon4x4; missing h264_cavlc_nc_predictor,h264_cavlc_residual_block
  FAIL intra_prediction: missing h264_intra4x4_pred,h264_intra16x16_pred,h264_chroma8x8_pred,h264_intra_mode_guard
  FAIL deblocking_writeback: present h264_deblock_writeback_ctrl; missing h264_deblock_bs,h264_deblock_thresholds,h264_deblock_edge,h264_deblock_edge_pipe

DECODE_REAL_INTRA=1
  FAIL bitstream_entropy: missing all mapped modules
  FAIL residual_dequant_transform: present h264_dequant4x4,h264_idct4x4,h264_recon4x4; missing h264_cavlc_nc_predictor,h264_cavlc_residual_block
  FAIL intra_prediction: present h264_intra4x4_pred,h264_intra16x16_pred; missing h264_chroma8x8_pred,h264_intra_mode_guard
  FAIL inter_prediction_mc_subpel: missing all mapped modules
  FAIL mv_prediction: missing all mapped modules
  FAIL dpb_reference_management: missing all mapped modules
  FAIL deblocking_writeback: missing all mapped modules
```

## Decode lineages

Measured decode roots in RTL: 4.

```text
decode_stub: product under DECODE_REAL_INTRA=0; complete categories inter_prediction_mc_subpel,mv_prediction,dpb_reference_management
h264_decode_top: product under DECODE_REAL_INTRA=1; complete categories <none>
h264_decode_core: dead/staged bench-only partial product datapath, not instantiated by stream_path; complete category mv_prediction only
h264_decode_skeleton: dead/resource-estimation bench-only fitter skeleton; complete categories residual_dequant_transform,intra_prediction,mv_prediction,dpb_reference_management,deblocking_writeback
```

Measurement correction: the text claim that `h264_dpb_one_ref` is instantiated in
four places is not what the parsed RTL shows. Source-graph parents are
`decode_stub` and `h264_decode_skeleton`; `h264_dpb.sv` defines the module, and
`h264_decode_core.sv` mentions it in comments but does not instantiate it.
Measurement wins.

## Gate assertion

Capability manifest: `fpga/Plex_MiSTer/rtl/decode_capability_modules.txt`.

Required categories:

```text
bitstream_entropy
residual_dequant_transform
intra_prediction
inter_prediction_mc_subpel
mv_prediction
dpb_reference_management
deblocking_writeback
```

Literal comparison: for each shippable product config (`DECODE_REAL_INTRA=0` and
`=1`), each category maps to required RTL module names. A category passes only if
all mapped modules are reachable from product root `emu` under that config.
Missing any mapped module makes that category fail; missing any category makes the
gate rc=1.

What this does not cover: semantic correctness, schedule/control wiring,
throughput, post-fit survival, or whether the mapped modules are connected to the
right signals. It catches assembled-decoder omissions and mutually-exclusive half
decoders at the source graph level.

## Red/green proof

```text
CURRENT_BASELINE_RC=1
DECODE_COMPLETENESS_CONFIG config=DECODE_REAL_INTRA=0 status=FAIL ...
DECODE_COMPLETENESS_CONFIG config=DECODE_REAL_INTRA=1 status=FAIL ...

SYNTHETIC_COMPLETE_RC=0
DECODE_COMPLETENESS_OK synthetic complete graph satisfies every category

SYNTHETIC_DROP_MV_RED_RC=1
DECODE_CAPABILITY config=synthetic category=mv_prediction status=FAIL
```

Validation:

```text
python3 tests/unit/test_decode_completeness_gate.py       rc=0
python3 scripts/check_decode_completeness.py --synthetic-complete rc=0
python3 tests/unit/test_unit_rollcall.py                  rc=0
```
