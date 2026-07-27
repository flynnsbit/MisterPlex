# MC Interpolation → DPB Fetch Interface Contract

**From:** w-mc (h264_mc_interp owner)
**To:** w-dpb (DPB fetch path owner)
**Module:** `fpga/Plex_MiSTer/rtl/h264_mc_interp.sv` on `feat/mc-interp`
**Commit:** `d2683f8`

## Interface Signals

```systemverilog
// Reference data input — 64-bit, row-major, MSB-first byte order
input  wire        ref_valid,
output reg         ref_ready,
input  wire [63:0] ref_data,
input  wire [3:0]  ref_byte_count,  // valid bytes in this word (1-8)
```

Standard ready/valid handshaking. Transfer occurs when `ref_valid && ref_ready`.

## Reference Window Requirements

| Mode | Window size | Bytes | 8-byte words |
|------|------------|------:|-------------:|
| Luma quarter-pel | (blk_w+5) × (blk_h+5) | up to 441 (21×21) | 56 |
| Luma P_Skip (cmd_skip_zero=1) | blk_w × blk_h | up to 256 (16×16) | 32 |
| Chroma eighth-pel | (blk_w+1) × (blk_h+1) | up to 81 (9×9) | 11 |

Block dimensions communicated via `cmd_blk_w` (4, 8, or 16) and `cmd_blk_h` (4, 8, or 16).

## Data Ordering

**Row-major raster order, MSB-first within each 64-bit word.**

For a luma 16×16 block at quarter-pel, the window is 21 columns × 21 rows.
Bytes arrive as: row 0 col 0, row 0 col 1, ..., row 0 col 20, row 1 col 0, ...

The top-left of the window is at integer position `(int_x - 2, int_y - 2)` where
`(int_x, int_y)` is the integer-pel position of the block's top-left corner.
The 6-tap FIR needs 2 samples before and 3 samples after the block boundary.

For P_Skip (cmd_skip_zero=1), no border is needed: window is exactly blk_w × blk_h,
starting at the integer-pel position.

For chroma, the window starts at `(int_x, int_y)` with +1 border on right and bottom
(the bilinear filter needs one additional row and column).

## ⚠️ CRITICAL: Reference Must Be DEBLOCKED

**The reference data delivered to this interface MUST come from the DEBLOCKED
picture buffer, not the raw reconstruction.**

H.264 motion compensation predicts from the output of the in-loop deblocking
filter (clause 8.7). Using non-deblocked reference data causes 8–25% pixel
mismatches that compound across all P-frames in a GOP. This was measured by
w-cabac on actual content.

`-skip_loop_filter all` was correct for intra verification and is **actively
wrong for inter prediction**.

## Performance

- My module processes data at 2 samples/cycle output
- Pipelined: compute starts after 6 rows loaded (luma) or 2 rows (chroma)
- **If ref_ready is high and ref_valid is low, my pipeline stalls 1:1**
- Measured compute: 220 cycles/MB at ideal memory (lower bound)
- Budget ceiling: 250 cycles/MB (w-c1 allocation)
- P_Skip: 132 cycles/MB (42% less bandwidth)

## What I Do NOT Care About

- How you fetch from DDR — that's your architecture decision
- Burst length, bank interleaving, arbitration — transparent to me
- Whether you cache, prefetch, or stream — as long as words arrive in order
- The clock domain — my module is purely synchronous, runs at any frequency

## What I DO Care About

1. **64-bit words arrive in raster order** — I unpack into a 2D buffer
2. **ref_byte_count is accurate** — last word may have fewer than 8 valid bytes
3. **ref_ready/ref_valid handshake is respected** — no data when ref_ready=0
4. **Deblocked reference only** — this is the requirement I cannot enforce from my side
