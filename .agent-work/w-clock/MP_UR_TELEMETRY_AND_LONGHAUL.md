# mp underrun telemetry + producer lead + reset_pix (rd-duck)

## (a) Observable underrun — fixed

| Before | After |
|--------|-------|
| `mp_rd_ur` only in `_unused_mp_flags` (DCE risk) | `(* noprune *) mp_rd_ur_sticky` + `mp_rd_ur_count` |
| Not in status | `stat_frame_underruns[15]=sticky`, `[14:0]=store_ur+mp_count` |
| | Toggle-sync pix→sys (safe CDC) |

Markers: `MP_UR_STICKY`, `mp_stat_frame_underruns` (elab greps).

## (b) Equal-rate drift — fixed

| Lever | Value |
|-------|-------|
| Producer lead | `MP_PROD_LEAD_PPM=1000` → `F_PIX=29_729_700` into rate-match |
| Backpressure | existing `in_ready` / skid AF / async almost_full |
| Prefill watermark | `PREFILL_GROUPS(16)` on product npx instance |
| Long-haul TB | ±1000 ppm pix + phases {0,16,18,34}, 4 frames, ur==0 |

Overflow throttles; underflow cannot — lead biases FIFO toward full side.

## (c) reset_pix

Async assert / sync deassert 2FF into `clk_pix` (`mp_reset_pix`). Raw `reset` no longer clocks pix domain flops.

## Tests

```bash
./tests/unit/test_present_multi_pixel_elab.sh
./tests/unit/test_present_npx_longhaul.sh
./tests/unit/test_present_mp_integrated.sh
```

No fit / no device / no glass claim.
