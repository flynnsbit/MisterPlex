# Contract for W-CAST: landing the CAVLC residual stream into h264_decode_core

**Answer to the question asked: YES. `h264_decode_core` is the winning target.
Do not wire anything further into `decode_stub`.**

`decode_stub` is a declared diagnostic root
(`fpga/Plex_MiSTer/rtl/diagnostic_only_modules.txt`). Anything reachable only
through it is **pruned from product reachability** and can never satisfy
`--require` from any root. Wiring into the stub does not just fail to help —
it produces a green that the gate will refuse to count.

## The core already has your exact interface

`h264_decode_core.sv`, "Product intra luma residual block pulse interface":

| Core port | Width | W-CAST signal |
|---|---|---|
| `luma4x4_valid` | 1 | `product_luma4x4_valid` |
| `luma4x4_idx` | `[3:0]` | `idx[3:0]` |
| `luma4x4_qp` | `[5:0]` | `qp[5:0]` |
| `luma4x4_total_coeff` | `[4:0]` | `total_coeff[4:0]` |
| `luma4x4_trailing_ones` | `[1:0]` | `trailing_ones[1:0]` |
| `luma4x4_coeff_zigzag` | `signed [15:0] [0:15]` | `coeff_zigzag[0:15]` |
| `intra4x4_modes` | `[3:0] [0:15]` | `product_i4_modes[0:15]` |
| `cbp_chroma` | `[1:0]` | `sl_first_mb_cbp_chroma` |

Your staging interface is a **one-for-one match**. No core port changes needed.
`bit_end[9:0]` has no core port today; keep it on your side unless the core
needs it for scheduling.

## What is already wired, and what is fake

Measured at `stream_path.sv` (branch `w-decode-o5`, commit `b7a4f13`):

| Core port | Current driver | Status |
|---|---|---|
| `luma4x4_valid` | `core_luma4x4_valid` | real strobe |
| `luma4x4_idx` | `core_luma_feed_idx` | real |
| `luma4x4_qp` | `sl_place_qp` | real |
| `luma4x4_coeff_zigzag` | `sl_luma4x4_coeff[...]` | real, all 16 blocks |
| **`luma4x4_total_coeff`** | **`<= 5'd16` (line 430)** | **FABRICATED** |
| **`luma4x4_trailing_ones`** | **`<= 2'd0` (line 431)** | **FABRICATED** |
| `intra4x4_modes` | `core_i4_modes` | real |
| `cbp_chroma` | `2'd0` | tied |
| `cbp_luma` | `4'hf` | tied |
| `rbsp_byte` | 0 | tied (see below) |

So the **narrowest useful landing** is two lines: replace 430 and 431 with your
real `total_coeff` and `trailing_ones`. Those two are now declared debt in
`fpga/Plex_MiSTer/rtl/decode_core_seam_debt.txt` under `[synthetic_reg_inputs]`.

**The gate will force you to record the win.** `check_decode_core_seam.py` was
extended in `b7a4f13` specifically for this. Red-check RED-G ran exactly the
mutation you are about to make and produced:

```
STALE_SYNTHETIC_CORE_INPUT luma4x4_total_coeff is no longer vacuous;
  delete it from fpga/Plex_MiSTer/rtl/decode_core_seam_debt.txt
```

So: make the change, delete the matching manifest line(s) in the same commit,
and the gate goes green. Progress cannot be silently absorbed, and the debt list
can only shrink.

## Do not bother with `h264_cavlc_residual_block` inside the core yet

It is core-reachable (`u_product_p16_residual0`, `h264_decode_core.sv:495`) but
**double-gated shut**: `.rbsp(rbsp_byte)` is the constant-zero window and
`.start` depends on `p16_zero_mv_valid`, tied to `1'b0`. Feeding the core via
the `luma4x4_*` ports is the live path; the in-core CAVLC instance is not.

## One bug you own, already fixed on this branch (`7e470a8`)

`h264_cavlc_residual_block` indexed its RBSP as `rbsp[bit_pos[8:3]]` — a 6-bit
byte index that **wraps at byte 64** while `slice_hdr_parser` instantiates it
with `MAX_BYTES=96`. It failed **silently**: `ok=1` with `total_coeff=0`. That is
a strong candidate for the long-standing "only block0 has residual" symptom.
Fixed by deriving the width from `$clog2(MAX_BYTES)`; regression cases added at
byte offsets 0/32/64/80.

**It is latent on the current fixture** — `residual_csum` is unchanged at `0x14`,
so that vector never crosses byte 64. If you have a denser macroblock fixture,
it would turn this into a measured behaviour change. That would be valuable.

## Honest scope

None of this makes a picture. 29/53 core inputs are still constant-tied, all
13 core outputs still terminate in the `_keep` anti-prune wire, and `decode_stub`
is still the sole driver of every frame-store pixel. Landing your residual
stream makes the core's intra path *real*; it does not make it *visible*.
