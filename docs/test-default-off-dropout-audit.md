# Default-off decoder dropout audit (W-GATE)

Audit date: 2026-07-28. Branch: `w-gate-inst-vacuity`.

## Raw drop-out set first

Reachable under `DECODE_REAL_INTRA=0` but not under `DECODE_REAL_INTRA=1`:

```text
decode_stub
h264_chroma_epel_block_8x8
h264_chroma_epel_sample
h264_deblock_writeback_ctrl
h264_dpb_i420_addr
h264_dpb_mb_write_addr
h264_dpb_one_ref
h264_inter_mc_16x16
h264_inter_mc_part
h264_luma_qpel_block_16x16
h264_luma_qpel_sample
h264_luma_ref_tap_addr
h264_mv_pred_16x16
h264_mv_pred_part
h264_ref_clamp
```

Counts:

```text
off_count=41
on_count=29
drop_count 15
gain_count 3
GAIN h264_decode_top
GAIN h264_intra16x16_pred
GAIN h264_intra4x4_pred
```

Specific residual/transform status:

```text
MODULE_STATUS h264_cavlc_residual_block off=False on=False dropout=False
MODULE_STATUS h264_dequant4x4 off=True on=True dropout=False
MODULE_STATUS h264_idct4x4 off=True on=True dropout=False
MODULE_STATUS h264_recon4x4 off=True on=True dropout=False
MODULE_STATUS h264_deblock_writeback_ctrl off=True on=False dropout=True
```

So: no dequant/IDCT/recon module drops; the CAVLC residual block is not product
reachable in either configuration; the deblock/DPB/inter subtree does drop.

## Classification

| Module | Classification | Reason |
| --- | --- | --- |
| `decode_stub` | legitimately stub-only | The diagnostic fallback stub itself is expected to disappear when `DECODE_REAL_INTRA=1`. |
| `h264_chroma_epel_block_8x8` | real decode machinery being bypassed | Chroma interpolation block path for inter/MC. |
| `h264_chroma_epel_sample` | real decode machinery being bypassed | Chroma interpolation sample primitive. |
| `h264_deblock_writeback_ctrl` | real decode machinery being bypassed | Deblock/writeback/DPB reference-publication control. |
| `h264_dpb_i420_addr` | real decode machinery being bypassed | DPB native-I420 address helper. |
| `h264_dpb_mb_write_addr` | real decode machinery being bypassed | Macroblock memory write-address helper. |
| `h264_dpb_one_ref` | real decode machinery being bypassed | One-reference DPB fetch path. |
| `h264_inter_mc_16x16` | real decode machinery being bypassed | 16x16 inter motion compensation. |
| `h264_inter_mc_part` | real decode machinery being bypassed | Partitioned inter motion compensation. |
| `h264_luma_qpel_block_16x16` | real decode machinery being bypassed | Luma quarter-pel block interpolation. |
| `h264_luma_qpel_sample` | real decode machinery being bypassed | Luma quarter-pel sample primitive. |
| `h264_luma_ref_tap_addr` | real decode machinery being bypassed | Luma reference tap-address helper. |
| `h264_mv_pred_16x16` | real decode machinery being bypassed | 16x16 motion-vector predictor. |
| `h264_mv_pred_part` | real decode machinery being bypassed | Partition motion-vector predictor. |
| `h264_ref_clamp` | real decode machinery being bypassed | Reference-window clamp helper. |

Finding: 14 of 15 dropouts are category (b). This is the same systemic class as
defect #19: enabling the nominal real path adds the intra top/predictors while
silently shedding DPB/inter/deblock/writeback machinery that was only reachable
through `decode_stub`.

## Gate extension

New explicit file: `fpga/Plex_MiSTer/rtl/default_off_drop_modules.txt`.

The instantiation gate now reports:

```text
DEFAULT_OFF_DEFINE_DROPS_STUB_ONLY_MODULE decode_stub defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_chroma_epel_block_8x8 defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_chroma_epel_sample defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_deblock_writeback_ctrl defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_dpb_i420_addr defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_dpb_mb_write_addr defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_dpb_one_ref defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_inter_mc_16x16 defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_inter_mc_part defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_luma_qpel_block_16x16 defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_luma_qpel_sample defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_luma_ref_tap_addr defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_mv_pred_16x16 defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_mv_pred_part defines=DECODE_REAL_INTRA=1
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_ref_clamp defines=DECODE_REAL_INTRA=1
RTL_MODULE_INSTANTIATION_OK ... default_off_dropouts=15 default_off_real_decode_dropouts=14 ...
```

## Red/green proof

Literal comparison: modules default-reachable from `emu` under QSF macros minus
modules reachable after each checked-in default-off macro is flipped on. Every
lost RTL module must be classified as `stub-only` or `real-decode-bypass`.

What it does not cover: correctness of the remaining real-intra path, post-fit
retention, or whether a classified real-decode dropout is acceptable for a
specific fit. It makes the loss impossible to miss in gate output.

Mutation evidence:

```text
DROPOUT_MISSING_DECL_RED_RC 1
DEFAULT_OFF_DEFINE_DROP_UNDECLARED h264_deblock_writeback_ctrl defines=DECODE_REAL_INTRA=1
RTL_MODULE_INSTANTIATION_FAIL: modules lost when product-default-off defines are enabled must be classified in fpga/Plex_MiSTer/rtl/default_off_drop_modules.txt

GENUINE_REACHABLE_DROPOUT_FALSE_RED_RC 1
RTL_MODULE_INSTANTIATION_FAIL: default-off drop declarations are not dropped by any discovered product-default-off define: h264_dequant4x4

DROPOUT_RESTORE_GREEN_RC 0
```
