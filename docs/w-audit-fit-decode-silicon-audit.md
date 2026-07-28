# W-AUDIT fit decode silicon audit

W-FIT claim under audit: branch `parent/integ-hour27` `8b7b45b`,
deployed bitstream `fb4bad849ad2db782a5004ce5a3471ce`, fitted from `5b68cc2`.

Artifact audited from current integration worktree (`parent/integ-hour27`
`fc89526`, report unchanged):
`fpga/Plex_MiSTer/remote_out/wfit-hour27-bdiag-b/Plex.fit.rpt`.

## Raw results

Independent parser:

```
FIT_ENTITY_ROWS 827
DEVICE_UTIL logic_alms 17706/41910 pct=42
DEVICE_UTIL block_bits 2970061/5662720 pct=52
DEVICE_UTIL m10k 453/553 pct=82
DEVICE_UTIL dsp 74/112 pct=66
```

Named module list from W-FIT broadcast, counted literally:

```
NAMED_SUMMARY present=4 absent=14 denominator=18
decode_stub             PRESENT  |sys_top|emu:emu|stream_path:spath|decode_stub:stub
h264_decode_core        ABSENT
h264_decode_top         ABSENT
h264_decode_skeleton    ABSENT
h264_dpb_one_ref        PRESENT  only under decode_stub
h264_dpb_i420_addr      PRESENT  only under decode_stub|h264_dpb_one_ref
h264_dpb_mb_write_addr  PRESENT  only under decode_stub|h264_dpb_one_ref
all 11 W-FIT grouped MC/ref/MV/intra sample modules ABSENT
```

All fitted `h264*` rows, regardless of W-FIT's named list:

```
H264_FIT_ROWS count=7
h264_deblock_writeback_ctrl  PRESENT only under decode_stub  17 ALUT / 12 reg
h264_dequant4x4              PRESENT only under decode_stub  585 ALUT / 32 DSP
h264_dpb_one_ref             PRESENT only under decode_stub  531 ALUT / 106 reg
h264_dpb_mb_write_addr       PRESENT only under decode_stub  94 ALUT
h264_dpb_i420_addr           PRESENT only under decode_stub  87 ALUT
h264_idct4x4                 PRESENT only under decode_stub  1905 ALUT
h264_recon4x4                PRESENT only under decode_stub  539 ALUT
```

Elaborated by Quartus but not present in the fit hierarchy:

```
h264_inter_mc_16x16
h264_inter_mc_part
h264_luma_qpel_block_16x16
h264_chroma_epel_block_8x8
h264_luma_ref_tap_addr
h264_ref_clamp
h264_mv_pred_16x16
h264_mv_pred_part
h264_luma_qpel_sample
h264_chroma_epel_sample
```

Capacity numbers for the fitted `decode_stub` hierarchy row:

```
DECODE_STUB_RESOURCE aluts=6448 regs=734 block_bits=2097152 m10ks=256 dsps=33
DECODE_STUB_M10K_SHARE       used_pct=56.5  device_pct=46.3
DECODE_STUB_BLOCK_BITS_SHARE used_pct=70.6  device_pct=37.0
DECODE_STUB_DSP_SHARE        used_pct=44.6  device_pct=29.5
```

W-FIT's source-check warning reproduced without a pipe:

```
python3 scripts/check_rtl_module_instantiations.py --help  rc=0
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=44 bench_only=24 root=emu
```

## Interpretation

### Could not break the central silicon claim

The deployed `fb4bad84` fit contains `decode_stub` under product
`stream_path` and contains no `h264_decode_core`, `h264_decode_top`, or
`h264_decode_skeleton` entity row. The real decoder root is absent from the
running bitstream.

Every fitted `h264*` entity I found is under
`|stream_path:spath|decode_stub:stub`. I could not construct an independent
post-fit read that places any decode logic outside the stub.

### Broke / narrowed W-FIT wording

The row-count denominator is not reproduced: I parse `827` entity rows from the
fit hierarchy table, not `1204`. If W-FIT used a broader table set, it needs to
name it. This does not change the module presence result.

The "three present decode modules" wording is undercounted. The three DPB rows
W-FIT named are present and stub-only, but the fit also contains
`h264_deblock_writeback_ctrl`, `h264_dequant4x4`, `h264_idct4x4`, and
`h264_recon4x4`, all stub-only. The stronger true statement is: **seven fitted
`h264*` entities are present, and all seven are reachable only through
`decode_stub`.**

The "all real decoders absent" wording is safe only if it means "no real decoder
root / no product decoder lineage." It is not safe as "no H.264 decode-related
entities exist," because IDCT/recon/dequant/writeback entities do exist under
the stub.

### Capacity argument survived

The M10K/block-bit/DSP capacity numbers match the fit report. Retiring
`decode_stub` would recover a very large share of the used memory resources:
`256/453` used M10Ks and `2,097,152/2,970,061` used block-memory bits.

### Additional measurement lesson

The compile log elaborated multiple modules that are absent from the fitted
hierarchy. `Info (12128): Elaborating entity ...` is not silicon presence
evidence. For this class of claim, fit hierarchy beats compile elaboration.

## Reproduction

```
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-audit
python3 scripts/w_audit_fit_decode_silicon_audit.py
```

No Quartus, deploy, `load_core`, DDR poke, or video capture is used.
