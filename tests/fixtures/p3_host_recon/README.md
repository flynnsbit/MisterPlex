# Phase 3 host reconstruction fixtures

These files are stable inputs/outputs for RTL testbenches.

- `plex_real_baseline_320x240_1f.264` — checked-in H.264 Baseline Annex-B IDR vector,
  intentionally **6739 bytes**.
- `mb0_luma_v1.json` — `format=misterplex.p3.luma_mb.v1`; MB0 Y-plane prediction,
  dequantized 4×4 coefficients, signed post-IDCT residual samples, and reconstructed pixels.
- `frame_mae_v1.csv` — `format=misterplex.p3.frame_mae.v1`; per-MB Y-plane MAE against
  FFmpeg `-skip_loop_filter all`.

Do not change field names, ordering, or vector bytes without updating the format version and
coordinating with RTL consumers.
