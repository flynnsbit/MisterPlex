# Phase 1a P_16x16 + P_Skip (320x240, 12 frames)

Constrained Baseline, CAVLC, I + 11 P. No B, no CABAC, no 8x8dct, 1 ref.

Verified with host `walkISliceResiduals` + `walkAllPSliceResiduals` (rejects Table 7-13 types 1–4 as `p_part`):

- I 300/300
- P 11/11 × 300/300

x264 frame stats: P intra 0.0%, P16..4 `4.6% 0 0 0 0`, skip 95.3%. I is 100% I_16x16 (V/DC, **no plane**).

## Encode

Checker + 16x16 moving block (no gradient, so no I16 plane / I-in-P).

```
x264 --profile baseline --level 3.1 --preset medium --bframes 0 --no-cabac \
  --no-8x8dct --weightp 0 --ref 1 --qp 25 --partitions none --fps 24 \
  --input-res 320x240 --aq-mode 0 --no-mbtree --psy-rd 0:0 --ipratio 1.0 \
  -o plex_phase1a_p16skip_320x240_12f.264 src_12f_320x240.yuv
```

`--partitions none` turns off `X264_ANALYSE_PSUB16x16` (p16x8 + p8x16 + p8x8).

## SHA256

```
9b49b7366c2be202ea2e26994c4f13d05dd82f3741fc3505a33e029e38e8632b  plex_phase1a_p16skip_320x240_12f.264
ba3dea60d1b06c13073c9a893d62d27135eadc5c02bb736bc6f840d87f251f98  gold_12f_320x240.yuv
ba3dea60d1b06c13073c9a893d62d27135eadc5c02bb736bc6f840d87f251f98  src_12f_320x240.yuv
```

`gold` is ffmpeg decode of the .264 (`yuv420p`). On this pattern it matches `src`.

Do not use `plex_inter_p16_baseline_320x240_12f.264` as the Phase 1a partition lock (I-in-P / richer residual).
