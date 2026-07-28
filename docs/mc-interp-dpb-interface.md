# MC Interpolation ↔ Datapath Interface Contract

**From:** w-mc (h264_mc_interp owner)
**To:** w-rel (datapath integration), w-dpb (DPB fetch)
**Module:** `fpga/Plex_MiSTer/rtl/h264_mc_interp.sv` on `feat/mc-interp`
**Updated:** 2026-07-27 (post #19 — integration spec for real datapath)

## Purpose

This contract defines what the decode datapath must provide to MC interpolation,
and what MC provides back. It is written so w-rel can instantiate `h264_mc_interp`
without ambiguity.

## Port List (complete, synthesis-ready)

```systemverilog
h264_mc_interp #(
    // Production: all FAULT_* = 0
) u_mc_interp (
    .clk            (clk_sys),
    .rst_n          (rst_n),

    // Command interface — one command per partition
    .cmd_valid      (mc_cmd_valid),       // datapath asserts when partition is ready
    .cmd_ready      (mc_cmd_ready),       // MC deasserts while busy
    .cmd_is_chroma  (mc_is_chroma),       // 0=luma, 1=chroma (Cb or Cr)
    .cmd_frac_x     (mc_frac_x),          // [1:0] luma quarter-pel X (from MV)
    .cmd_frac_y     (mc_frac_y),          // [1:0] luma quarter-pel Y (from MV)
    .cmd_chroma_dx  (mc_chroma_dx),       // [2:0] chroma eighth-pel X
    .cmd_chroma_dy  (mc_chroma_dy),       // [2:0] chroma eighth-pel Y
    .cmd_blk_w      (mc_blk_w),           // [4:0] block width: 4, 8, or 16
    .cmd_blk_h      (mc_blk_h),           // [4:0] block height: 4, 8, or 16
    .cmd_skip_zero  (mc_skip_zero),       // 1=P_Skip (integer-pel, no border)
    .cmd_ref_x      (mc_ref_x),           // [15:0] signed — for cache key only
    .cmd_ref_y      (mc_ref_y),           // [15:0] signed — for cache key only

    // Reference data input — 64-bit, row-major, MSB-first
    .ref_valid      (dpb_ref_valid),      // w-dpb asserts when word available
    .ref_ready      (mc_ref_ready),       // MC backpressure
    .ref_data       (dpb_ref_data),       // [63:0] up to 8 bytes per word
    .ref_byte_count (dpb_ref_byte_count), // [3:0] valid bytes (1-8)

    // Predicted sample output — 2-wide
    .pred_valid     (mc_pred_valid),      // MC asserts when samples ready
    .pred_ready     (recon_pred_ready),   // downstream (residual add) backpressure
    .pred_sample0   (mc_pred0),           // [7:0] first sample
    .pred_sample1   (mc_pred1),           // [7:0] second sample (valid if pred_pair)
    .pred_pair      (mc_pred_pair),       // 1=two samples this cycle
    .pred_last      (mc_pred_last),       // 1=last sample(s) of this partition

    // Diagnostic
    .cycle_count    (mc_cycle_count)      // [15:0] cycles for last command
);
```

## Command Sequencing (per macroblock)

For a P-frame macroblock, the datapath issues:
1. **Luma partition(s):** one `cmd_valid` per partition (16×16, 16×8, 8×16, 8×8, or sub-8×8)
2. **Cb:** one command with `cmd_is_chroma=1`, block is half the luma partition size
3. **Cr:** one command with `cmd_is_chroma=1`, same geometry as Cb

For P_Skip macroblocks: single command with `cmd_skip_zero=1`, `blk_w=16`, `blk_h=16`.

Commands must be issued **one at a time** (wait for `pred_last` before next `cmd_valid`).

## Reference Window Requirements

| Mode | Window cols × rows | Bytes (max) |
|------|-------------------|------------:|
| Luma quarter-pel | (blk_w+5) × (blk_h+5) | 441 (21×21) |
| Luma P_Skip | blk_w × blk_h | 256 (16×16) |
| Chroma eighth-pel | (blk_w+1) × (blk_h+1) | 81 (9×9) |

## Edge Clamping Contract

**w-dpb MUST apply edge clamping before streaming the reference window.**

When MVs point outside the picture boundary, reference samples must be clamped
to the nearest boundary pixel (H.264 clause 8.4.2.2.1, NOTE). Specifically:
- `x < 0` → fetch from `x = 0`
- `x >= pic_width` → fetch from `x = pic_width - 1`
- `y < 0` → fetch from `y = 0`
- `y >= pic_height` → fetch from `y = pic_height - 1`

**An off-by-one error here (clamping to boundary±1) is detected by 34% of my
edge test vectors.** This was measured by fault injection (2026-07-27).

## ⚠️ CRITICAL: Reference Must Be DEBLOCKED

The reference surface MUST be post-deblock (clause 8.7). Non-deblocked references
cause 8–25% pixel errors that compound across all P-frames in a GOP.

## Bandwidth Demand

### Per macroblock (worst case: all quarter-pel j-position)
- Luma: 21×21 = **441 bytes**
- Cb: 9×9 = **81 bytes**
- Cr: 9×9 = **81 bytes**
- **Total: 603 bytes/MB**

### Per macroblock (P_Skip, integer-pel)
- Luma: 16×16 = **256 bytes**
- Cb: 8×8 = **64 bytes**
- Cr: 8×8 = **64 bytes**
- **Total: 384 bytes/MB**

### Per frame at 25 fps

| Geometry | MBs/frame | Worst-case bytes/frame | Bytes/sec | 64-bit words/sec |
|----------|-----------|----------------------:|----------:|-----------------:|
| 624×480 (39×30) | 1170 | 705,510 | 17.64 MB/s | 2.20M |
| 640×480 (40×30) | 1200 | 723,600 | 18.09 MB/s | 2.26M |

**Both fit comfortably within 64-bit DDR bandwidth at 100 MHz (800 MB/s).**
The geometry must come from `sps_parser.mb_width` — do NOT hardcode 39 or 40.

### Cycle budget
- **220 cycles/MB** measured (146 luma + 37 Cb + 37 Cr)
- **132 cycles/MB** for P_Skip (42% less)
- DDR stall penalty: **1:1** (every cycle `ref_valid=0` while `ref_ready=1` is wasted)
- At 45 MHz (w-arch v6 REQUIRED): 1,250 cycles/MB available → 5× headroom
- At 20 MHz (FAILS per w-arch v6): 556 cycles/MB → still fits compute, but total pipeline does not

## DSP Usage

**ZERO.** All luma FIR taps use shift-add: `x*5=(x<<<2)+x`, `x*20=(x<<<4)+(x<<<2)`.
Chroma bilinear uses `(* multstyle = "logic" *)`. Device has only 39 DSP blocks free;
MC consumes none, leaving full budget for CABAC/dequant.

## Output Contract (to residual add)

- `pred_valid` + `pred_ready` handshake, standard ready/valid
- 2-wide output: `pred_sample0` always valid, `pred_sample1` valid when `pred_pair=1`
- Samples arrive in **raster order** (row 0 col 0, row 0 col 1, ...)
- `pred_last` asserts on the final beat of each partition
- Output data is **unsigned 8-bit** (already clipped to [0,255])

## Width Agnosticism

This module is **width-agnostic**. It processes whatever partition geometry and
MV the command port specifies. The 1170-vs-1200 question does not affect my logic —
it affects how many commands per frame the datapath issues, and whether w-dpb's
edge clamping uses `pic_width=624` or `pic_width=640`.

**Recommendation:** read `pic_width_in_mbs` from `sps_parser` and derive all
MB-column counts from it. Do not hardcode geometry anywhere in the pipeline.
