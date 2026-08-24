# Full-slice CAVLC feed (mb_ctrl walker)

`slice_hdr_parser` MAXB=48 still owns **only** the first luma 4x4 (csum `0x14` / recon_sig `0x3b`). Do not walk the rest of the slice with that window.

`nalu_scanner` already dumps the VCL RBSP into `h264_slice_rbsp_ram` (8K) via `sl_rbsp_*`. That is the bitstream.

`apply_itu_fix = false`. No FIT_GO. HEVC stays in `rtl/hevc/` (secondary).

Bit index is MSB-first: `bit_pos = byte*8 + (7-bpos)` so `[2:0]==0` is bit7 of that byte.
`cur_bit = rbsp[byte][7 - bit_pos[2:0]]` (matches `h264_bit_reader` / `h264_mb_ctrl`).

---

## 1) `bit_offset_end` / walker start

Already exported by `slice_hdr_parser`:

| Port | Meaning | Next syntax |
|---|---|---|
| `bit_pos_hdr[16:0]` | First bit of **`first_mb_type` ue** (slice header + deblock offsets done) | `mb_type` of MB0 |
| `bit_pos_resid[16:0]` | First bit **after** the MB0 first luma 4x4 CAVLC | Next residual of MB0, **not** MB1 |
| `bit_pos_valid` | Both latched | |

**Walker start:** `h264_bit_reader.load` with `bit_pos_i = bit_pos_hdr`, then **re-parse `mb_type` from bits**.

Do **not** jump to `bit_pos_resid` unless you also skip I4 / chroma pred / CBP / qpδ (you have not).
Do **not** reuse the 48B `first_mb_type` latch after MB0.

`byte = bit_pos[16:3]`, `bit = bit_pos[2:0]`.

After each `h264_cavlc_residual_block`:

```
bit_offset_start = {7'd0, bit_pos[2:0]}   // offset inside the 64B window
// on cav_done:
bit_pos += (bit_offset_end - bit_offset_start)
```

Then refill the 64B window from `sl_rbsp` RAM at the new byte. `sat9` stays between CAVLC s16 and dequant s9.

---

## 2) Syntax order after `bit_pos_hdr` (Constrained Baseline)

Use `h264_bit_reader`: `start_ue` / `start_se` / `start_u` + `u_n`. Wait `syn_done && syn_ok`.

### P slice `mb_skip_run` (7.3.4) — this was the MB5 miss

Read `mb_skip_run` **ue** only:
1. at the start of a P slice (`bit_pos_hdr` is this bit), and
2. after a **coded** MB (P_16x16 / I-in-P).

Do **not** read it after a P_Skip. After the last skip of a run (`skip_run` counted down to 0), the next bits are **`mb_type`**. That next ue is often 0 (`P_L0_16x16`). Reading it as another skip_run is how MB5 died `p_part`.

- `skip_run == 0`: current MB is coded; parse `mb_type`.
- `skip_run == N>0`: emit N P_Skip MBs (`mvd=0`, `p_skip=1`, no residual), then `mb_type`.
- After a coded MB: read a **new** skip_run (0 means the next MB is coded immediately).

RTL lock (h264_mb_ctrl): `need_skip <= p_slice && !is_pskip` after commit. After a skip with `skip_run==0`, do **not** re-read skip_run; next bits are `mb_type` (`H_TYPE`).


Earlier report that MB5 is P_16x16 was the skip_run eat (type-0 bits). After a correct skip_run parse:
Host walk of `plex_inter_p16_baseline_320x240_12f.264` first P (320x240, CAVLC, header flags parsed): MB0–2 `P_16x16` (cbp ue 47/23/34), MB3–4 `P_Skip`, **MB5 `P_L0_L0_16x8` (Table 7-13 type 1)**. Later P slices also hit `P_8x16` / `P_8x8`. x264 `--partitions none` does **not** disable 16x8/8x16.

So `me_inter` at 7/300 is residual desync after an unconsumed 16x8 (two MVD pairs; CBP ue then ≥48). `cbp_inter` table is the FFmpeg inter map and is fine. Do not add P_16x8 to Phase 1a. Re-encode a true 16x16+Skip clip; do not treat this fixture as Phase 1a-only.

### I_NxN (`I` slice, `mb_type` ue == 0)
1. 16x `prev_intra4x4_pred_mode_flag` **u(1)**; if 0: `rem_intra4x4_pred_mode` **u(3)**
   - 4x4 order: **0,1,4,5,2,3,6,7,8,9,12,13,10,11,14,15**
2. `intra_chroma_pred_mode` **ue** (0..3)
3. `coded_block_pattern` **me** (ue then `cbp_intra_of`)
4. If `cbp != 0`: `mb_qp_delta` **se**
5. Residual via `h264_residual_seq`

### I_16x16 (`I` slice, `mb_type` ue 1..24)
No 4x4 modes. Pred mode + CBP packed in `mb_type` (Table 7-11).
`cbp_luma` is 0 or 15. `cbp_chroma` from the same table.
1. `intra_chroma_pred_mode` **ue**
2. `mb_qp_delta` **se** (always)
3. Residual: luma DC (always), luma AC **only if `cbp_luma != 0`**, then chroma

### P_L0_16x16 (`P` slice, `mb_type` ue == 0) — Phase 1a
1. `ref_idx_l0` **te** only if `num_ref_idx_l0_active > 1` (Phase 1: 1 ref → **omit**)
2. `mvd_l0[0].x` **se**, `mvd_l0[0].y` **se**
3. `coded_block_pattern` **me** (`cbp_inter_of`)
4. If `cbp != 0`: `mb_qp_delta` **se**
5. Residual

### P_Skip
No `mb_type` bits after the skip-run, no MVD, no CBP, no residual. `mvd = 0`. `h264_mv_pred_16x16` `p_skip=1`.

IPCM (25) / other P partitions: reject this phase.

---

## 3) Residual blocks (`h264_residual_seq`)

Pulse `start_mb` after CBP / qpδ. Pulse `advance` **only after** `cav_done` of a presented block.

Uncoded luma 8x8s are skipped inside the seq. Do **not** wait on `blk_valid==0` mid-MB; if `mb_res_done` rises, that MB has no more residual.

| When | `blk_id` | `max_coeff` | `coeff_token_table` | nC |
|---|---|---|---|---|
| I16 first | 16 luma DC | 16 | 7 = use nC | nC of luma 4x4 (0,0) |
| luma 4x4, 8x8 CBP bit set | 0..15 decoder order | 16, or **15** if I16 AC | 7 = use nC | luma nA/nB |
| `cbp_c != 0` | 17 Cb DC, 18 Cr DC | **4** | **4** (ITU chroma-DC / table 4) | unused |
| `cbp_c == 2` | 19..22 Cb AC, 23..26 Cr AC | **15** | 7 = use nC | chroma AC left/up TotalCoeff |
| `cbp_c == 0` | none | | | |
| `cbp_c == 1` | DC only | | | |

`cbp_chroma = cbp[5:4]`. `cbp_luma = cbp[3:0]`.

Chroma AC 4x4 raster per plane: `blk_x = i[0]`, `blk_y = i[1]`. `chr_cb=1` for Cb.

MB0 4x4-0 golden `0x14` / `0x3b` is still the first luma 4x4 of I_NxN. Later blocks use this cursor.

---

## 4) Modules

| File | Role |
|---|---|
| `h264_bit_reader.sv` | ue/se/u(n) + get_bit on the 8K RAM. Ports unchanged: `load`/`bit_pos_i`/`rbsp_len`/`ram_*`/`start_ue`/`start_se`/`start_u`/`u_n` → `syn_done`/`ue_val`/`se_val`/`bit_pos` |
| `h264_residual_seq.sv` | next coded block; extra outs `coeff_token_table[2:0]`, `chr_cb` (old named ports still match) |
| `h264_cavlc_residual_block` | already in tree; `coeff_token_table==4` is chroma DC |
| `h264_coeff_sat9` | s16 → s9, stays |

New seq ports are outputs only. Existing `h264_mb_ctrl` named instance still elaborates; wire `coeff_token_table` when you stop inventing table 4 vs nC:

```
cav_table <= rseq_cdc ? 3'd4 : nC_table;
```

or use the new `coeff_token_table` (4 or 7). `7` means "compute nC table 0..3".


---

## 5) Chroma AC nC (the live hole)

`h264_cavlc_nc_predictor` is correct. **Do not feed it luma `tc_left` / `tc_up` for chroma AC.**

Planes are separate. 2x2 4x4s per 8x8: `x=blk_x[0]`, `y=blk_y[0]`. `chr_cb` from `h264_residual_seq`.

| Neighbor | When | TC source |
|---|---|---|
| nA left | `x==0` | left MB, same plane, `{cb, y}` (its right column, `x==1`) |
| nA left | `x==1` | current `{cb, y, x=0}` |
| nB up | `y==0` | above MB, same plane, `{mb_x, cb, x}` (its bottom row, `y==1`) |
| nB up | `y==1` | current `{cb, y=0, x}` |

If the neighbor **MB exists** but `cbp_c != 2`, those AC TotalCoeff are **0** and **available**.
If the neighbor MB is **missing** (pic/slice edge), unavailable → predictor: both missing ⇒ `nC=0`.

Chroma DC: `coeff_token_table=4`, nC unused.

RAM sizes (today's `[0:1]` / `[0:39]` overflow at MB1 Cr / mb_x>=10):

```
tc_chr_cur  [0:7]           // {cb,y,x}
tc_chr_left [0:3]           // {cb,y}
tc_chr_up   [0:MB_W*4-1]    // {mb_x,cb,x}  MB_W=80 for 720p-class
```

Index helpers: `rtl/h264_chroma_nc.svh` (`h264_chr_cur_i` / `left_i` / `up_i`).

Write **every** chroma AC slot (decoded or zero). `tc_chr_left[rseq_cb] <= cav_tc` is wrong (drops `y`, never writes `up`).


---

## 6) P-slice header (no 3-bit skip)

`slice_hdr_parser` today jumps non-IDR `frame_num` → `slice_qp_delta`. That drops three **u(1)** flags that x264 usually codes as 0 (looks like “skip 3 bits” on this clip, and breaks if any flag is 1):

After `frame_num` (poc_type 2, `nal_ref_idc != 0`, P slice):

1. `adaptive_ref_pic_marking_mode_flag` **u(1)**. If 1: MMCO loop until `memory_management_control_operation == 0`.
2. `num_ref_idx_active_override_flag` **u(1)**. If 1: `num_ref_idx_l0_active_minus1` **ue** (Phase 1 stays 1 ref).
3. `ref_pic_list_modification_flag_l0` **u(1)**. If 1: modification loop until `modification_of_pic_nums_idc == 3`.

Then `slice_qp_delta` **se** and deblock as now.

`bit_pos_hdr` is the first bit of **`mb_skip_run`** on P (not `mb_type`). Parse those three flags; do not hard-skip 3 bits.

Phase 1a partition gold: `tests/fixtures/h264_phase1a_p16skip/` (I 300/300, 11 P 300/300, x264 P intra 0, P16/skip only).

---

## 7) Deblock chroma (`is_chroma`)

Current `ST_DB_LD`/`ST_DB_WR` is **luma-only** (`db_idx` 0..15 vertical then horizontal on `mb_pix`). `.is_chroma(1'b0)` is correct for that loop. Do **not** tie `is_chroma` to `filt_plane` (`filt_plane` is COMMIT store, not deblock).

When chroma edges are added: `is_chroma=1` and `qp_avg` = **qPc** (not QPy). ITU 8.7.2.

## 8) Chroma QP + chroma DC 2x2 (helper RTL, not instanced)

- `rtl/h264_chroma_qp.sv` — Table 8-15. `qpc = kChromaQP[clip(qpy + chroma_qp_index_offset, 0, 51)]`.
- `rtl/h264_chroma_dc_hadamard.sv` — host `invChromaDc2x2` / FFmpeg `ff_h264_chroma_dc_dequant_idct`. `qp` **must** be qPc. Scan `[0]=(0,0),[1]=(1,0),[2]=(0,1),[3]=(1,1)`. Do not sat9 `dc_out`.
- Icarus: qp=25 scan `{1,0,0,0}` → `dc_out={88,88,88,88}`.
- Phase 1a gold PPS `chroma_qp_index_offset=0` (qPc==table[QPy]; QPy=25 → 25).
- `pps_parser` `ST_CHR` already consumes that **se** into `ue_val` and drops it. Export `se_of(ue_val)` when wiring; do not re-parse.
- Do not instantiate from `Plex.sv`. MisterFPGA instantiates in `mb_ctrl` (chroma IQ/DC, later chroma deblock).
