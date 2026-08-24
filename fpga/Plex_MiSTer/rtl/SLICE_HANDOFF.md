# Slice handoff contract (code against this)

Bit index is MSB-first: `bit_pos = byte*8 + (7-bpos)` so `[2:0]==0` is bit7 of that byte.
`cur_bit = rbsp[byte][7 - bit_pos[2:0]]` (matches `h264_mb_ctrl`).

## 1) `bit_offset_end` from `slice_hdr_parser`

Already exported:

| Port | Meaning | Next syntax |
|---|---|---|
| `bit_pos_hdr[16:0]` | First bit of **`first_mb_type` ue** (slice header + deblock offsets done) | `mb_type` of MB0 |
| `bit_pos_resid[16:0]` | First bit **after** the MB0 first luma 4×4 CAVLC (ST_DONE) | Next residual block of MB0, **not** MB1 |
| `bit_pos_valid` | Both latched | |

**Walker start:** `bit_pos <= bit_pos_hdr`, then **re-parse `mb_type` from bits**. Do not jump to `bit_pos_resid` unless you also skip I4/chroma/CBP/qpδ (you have not). Do not use the 48B `first_mb_type` latch after MB0.

`byte = bit_pos[16:3]`, `bit = bit_pos[2:0]`.

## 2) Syntax order after `bit_pos_hdr` (Constrained Baseline)

### Every P slice, before each coded MB
`mb_skip_run` **ue**. Skip that many P_Skip MBs (no further bits; MV = pred / skip_zero). Then one coded MB.

### I_NxN (`I` mb_type ue == 0)
1. 16× `prev_intra4x4_pred_mode_flag` **u(1)**; if 0: `rem_intra4x4_pred_mode` **u(3)** (decoder order 0,1,4,5,2,3,6,7,8,9,12,13,10,11,14,15)
2. `intra_chroma_pred_mode` **ue** (0..3)
3. `coded_block_pattern` **me** (ue of the mapped code; use existing `cbp_intra_of`)
4. If `cbp != 0`: `mb_qp_delta` **se**
5. Residual (below)

### I_16x16 (`I` mb_type ue 1..24)
No 4×4 modes. Mode / CBP packed in `mb_type` (Table 7-11).
1. `intra_chroma_pred_mode` **ue**
2. `mb_qp_delta` **se** (always)
3. Residual: luma DC, 16 luma AC, chroma

### P_L0_16x16 (`P` mb_type ue == 0)  — Phase 1a
1. `ref_idx_l0` **te** only if `num_ref_idx_l0_active > 1` (Phase 1: 1 ref → **omit**)
2. `mvd_l0[0].x` **se**, `mvd_l0[0].y` **se**
3. `coded_block_pattern` **me** (`cbp_inter_of`)
4. If `cbp != 0`: `mb_qp_delta` **se**
5. Residual

### P_Skip
No `mb_type`, no MVD, no CBP, no residual. `mvd = 0`. `h264_mv_pred_16x16` `p_skip=1`.

IPCM (25) / other P partitions: reject this phase.

## 3) Chroma DC+AC CAVLC

`cbp_chroma = cbp[5:4]` (after me map). `cbp_luma = cbp[3:0]` (four 8×8 flags).

| When | Blocks | `max_coeff` | `coeff_token` table | nC |
|---|---|---|---|---|
| I16 first | luma DC | 16 | nC of luma 4×4 (0,0) | `h264_cavlc_nc_predictor` |
| luma 4×4 | order **0,1,4,5,2,3,6,7,8,9,12,13,10,11,14,15** if that 8×8 CBP bit (or all 16 AC if I16) | 16, or **15 AC-only** if I16 | nC luma | same |
| `cbp_c != 0` | Cb DC then Cr DC | **4** | **table 4** (`coeff_token_table=3'd4`) | nC unused |
| `cbp_c == 2` | 4× Cb AC then 4× Cr AC, 4×4 raster 0..3 | **15** | nC chroma (left/up chroma AC TotalCoeff) | chroma RAM |

If `cbp_c == 0`: no chroma residual. If `cbp_c == 1`: DC only.

After each `h264_cavlc_residual_block`: `bit_pos += (bit_offset_end - bit_offset_start)` in the 64B window, then refill window from `sl_rbsp` RAM. `sat9` stays.

MB0 4×4-0 golden `0x14` / `0x3b` is still the first luma 4×4 of I_NxN. Later blocks use this cursor.
