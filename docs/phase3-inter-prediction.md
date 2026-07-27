# Phase 3 inter prediction scope

This is the host-side scoping note for moving beyond IDR-only decode. No device access or
Quartus fit was used.

## Survey first: what we have to support

Available host-side assets already used as Plex-library/test content are H.264 Constrained
Baseline and contain **I/P only** (no B frames). Exported decoder motion vectors show quarter-pel
motion (`motion_scale=4`) even for Baseline content.

| Source | Frames | Types | B? | Motion-vector partitions | Max motion |
|---|---:|---|---:|---|---|
| `assets/avsync/sync_trekmatch_320x240_24_blip.mp4` | 720 | I=60 P=660 | 0 | 16x16=197307, 16x8=658, 8x16=296, 8x8=444 | 9.75×13.00 px |
| `assets/avsync/sync_24fps_blip.mp4` | 720 | I=60 P=660 | 0 | 16x16=195841, 16x8=376, 8x16=1264, 8x8=1436 | 12.50×19.00 px |
| `assets/avsync/sync_60fps_blip.mp4` | 1800 | I=30 P=1770 | 0 | 16x16=516271, 16x8=1314, 8x16=3334, 8x8=3936 | 12.50×20.00 px |
| `assets/avsync/sync_trekmatch_1080p24_blip.mp4` | 720 | I=35 P=685 | 0 | 16x16=5378814, 16x8=1730, 8x16=3562, 8x8=10356 | 55.00×37.00 px |

The checked-in inter vector deliberately pulls the cheap profile lever:

```text
scripts/gen_test_annexb_inter.py → plex_inter_p16_baseline_320x240_12f.264
bytes=27653 md5=fe5ba815b4d67b5b24d7de496facb15b
frames=12 I=1 P=11 B=0 refs=1 has_b_frames=0
x264: cabac=0:bframes=0:ref=1:weightp=0:8x8dct=0:partitions=none
motion vectors=3095, partition set={16x16}, max motion=(72,36) quarter-pel = 18.00×9.00 px
```

**Conclusion:** if `w-a4`/PMS can force Baseline/CAVLC, `bframes=0`, `ref=1`, `weightp=0`, and
P16×16-only partitions, the first hardware inter rung is much smaller: one past reference frame,
one vector per inter MB, no B reference list, no weighted prediction, no CABAC, and no sub-MB
partition scheduler. Quarter-pel interpolation remains mandatory.

If PMS cannot disable sub-MB partitions, the survey says we must support at least P16×16, P16×8,
P8×16, and P8×8. B-frames and weighted prediction did not appear in the surveyed Baseline assets,
but direct H.264 Parts can still be High/CABAC and must not be assumed safe.

## Goldens added

`tests/fixtures/p3_inter_pred/` contains:

- `plex_inter_p16_baseline_320x240_12f.264` — deterministic Annex-B source vector.
- `pframe1_mb_v1.json` (`format=misterplex.p3.inter_mb.v1`) — frame 1 per-MB motion partition
  data plus reconstructed Y samples.
- `frame_mae_v1.csv` (`format=misterplex.p3.inter_frame_mae.v1`) — all 12 frames × 300 MBs,
  Y-plane MAE versus FFmpeg decode.

`test_p3_inter_pred_vectors` regenerates the vector byte-for-byte, decodes with libav motion-vector
export, verifies the narrow profile (`I=1 P=11 B=0 refs=1 parts=16x16`), and checks the JSON/CSV
fixtures. Red perturbions cover both MV data and MAE rows.

## Hardware cost and memory path

Inter prediction is external-memory work, not BRAM work.

| Target | YUV420 reference frame | RGB565 output frame | Notes |
|---|---:|---:|---|
| 320×240 | 115,200 B | 153,600 B | feasible bandwidth even on modest external memory |
| 640×480 | 460,800 B | 614,400 B | not BRAM-resident; needs external memory |
| 720p | 1,382,400 B | 1,843,200 B | DDR3-only territory |

For 640×480 P16×16 quarter-pel, a rough per-frame memory budget is:

- reference read: ~0.72 MB/frame (luma 6-tap halo + chroma bilinear halo)
- decoded YUV reference write: 0.46 MB/frame
- RGB565 present write: 0.61 MB/frame
- total: ~1.8 MB/frame → ~54 MB/s at 30 fps, ~108 MB/s at 60 fps before burst inefficiency

If P8×8/sub-MB partitions are allowed, interpolation halos increase reference reads; budget closer
to ~2.2–2.6 MB/frame at 640×480 is a safer planning number (~66–78 MB/s at 30 fps, ~132–156 MB/s
at 60 fps). Multiple references multiply the reference-read pressure and require a reference-list
manager.

**Architecture implication:** inter prediction should target the DDR3-backed frame/reference store.
The SDRAM path is currently not dependable, and BRAM cannot hold even one 640×480 RGB565 frame.
The reported DDR3 path around ~160 MB/s is barely enough for 640×480p60 P16×16 with tight bursts;
raising the DDRAM clock toward the expected ~800 MB/s class would make 480p60 comfortable and leave
headroom for sub-MB partitions. Until then, 320×240 or 480p30 is the safer inter-prediction target.

## Coordination note for `w-a4`

Request sent to `w-a4`: confirm whether the 480p Plex transcode profile can force Baseline/CAVLC,
P-only, one reference, weighted prediction off, and ideally P16×16-only partitions. The current
`buildUniversal()` request only sets resolution/bitrate/quality; it does not explicitly request
these H.264 encoder constraints.
