# Phase 3.3l — Inv quant + 4×4 IDCT + Intra pred (FPGA)

**Status:** 3.3l-0 done; 3.3l-1 **host goldens locked** (`res_csum` XOR sat8 full-16 = **0x14** / 20); lab RBF **`820484a6`** (post Q-fix1) — **`res_dc=-24` OK**, **`res_csum` raw[13] live but ≠0x14 (unstable) → hard gate FAIL**; **R-csum1 in-flight** (running XOR + ST_PLACE `lev[]` csum fix); 3.3l-2 **host paint goldens + RTL plug sketch DONE** — **do not start 3l2 paint fit until hard `res_csum=20` PASS post-deploy**  

**Depends on:** 3.3k residual levels/runs → `residual_dc` (HW-green); **3.3l-1 hard `res_csum=20` after R-csum1 BUILD_OK + sole deploy**  
**Product rule:** hybrid host recon → F1 still owns present until FPGA mae is competitive.  
**No Quartus for 3.3l-0 / host 3.3l-1 / host 3.3l-2 / L-3l2-rtl / L-csum-note** — paint fit only after hard csum green + sole build free.

## Goal

Move from **coeff probe** (`residual_dc = scan coeff[0]`) to **real recon pixels** on FPGA:

1. Inverse quantize first residual 4×4  
2. 4×4 integer IDCT (FFmpeg `ff_h264_idct_add`)  
3. Intra prediction (first MB, then all MBs)  
4. Write reconstructed samples into `frame_store` (F3 diagnostic path)

Host reference (bit-exact vs FFmpeg no-deblock):  
`host/libmisterplex/h264_recon.hpp` — `dequant4x4`, `idct4x4_add`, `predI4` / I16 / chroma.

## Where we are (3.3k baseline)

| Piece | Location | State |
|-------|----------|--------|
| Slice header + mb_type + QP | `slice_hdr_parser.sv` | done |
| CAVLC first residual (nC=0) | same: levels, total_zeros, run_before, ST_PLACE | done |
| Export | `residual_ok`, `residual_tc`, `residual_t1`, `residual_dc` | golden `-24` |
| Paint | `decode_stub.sv` MB0 gray = clamp(128+dc) | diagnostic only |
| Capture | nalu_scanner + MAXB=**48 B** RBSP | first residual ~17 B |
| Product present | host `reconISlice` → F1; `host_owns_fs` | unchanged |
| Fit (5CSEBA6, post-3.3k / current `Plex.fit.summary`) | ALM **22%** (9.4k/41.9k), M10K **74%** (407/553), bits 56%, DSP 33% | headroom: **ALM**, **DSP**; **M10K is tight** |

Golden Baseline F3 vector (`scripts/gen_test_annexb_real.py`):  
`mb0=0` (I_NxN), `qp=25`, first residual `tc=8 t1=3 coeff[0]=-24`.

---

## Architecture

### Dataflow target

```text
bitstream_fifo → nalu_scanner
                    ├─ SPS/PPS parsers (unchanged)
                    └─ slice path:
                         headers + first MB meta (existing bit-walk)
                         → residual CAVLC (extend ST_PLACE → full coeff[16])
                         → inv_quant 4×4
                         → idct4x4_add onto pred
                         → intra pred (I4 / later I16+chroma)
                         → pixel pack RGB565
                         → frame_store wr_en (F3; gated by host_owns_fs)
```

### Module split (new / grow)

| Module | Role | BRAM? |
|--------|------|-------|
| `slice_hdr_parser` | Keep header + CAVLC; **export full `coeff[0:15]`** after ST_PLACE | no (regs) |
| `inv_quant4` (new) | LevelScale × shift; FFmpeg `(level*qmul+32)>>6` | no |
| `idct4x4` (new) | Multi-cycle butterfly = `ff_h264_idct_add` | no |
| `intra_pred4` (new) | Modes 0–8 + DC avail; later I16/chroma | no |
| `mb_recon` (new or in stub) | Seq: pred → idct-add → MB buffer → RGB | first MB: regs only |
| `decode_stub` → evolve | Consume recon pixels instead of gray DC | no extra |
| Neighbour store (all-MB only) | Top row Y/UV + TC for nC | **yes, small** |

**Do not** store full YUV frame in M10K: write RGB565 into existing dual-bank `frame_store` as MBs finish.

---

## What stays logic-only (no new M10K)

Safe for 3.3l first-MB and most of all-MB math:

| Item | Why logic |
|------|-----------|
| `lev[0:15]`, `runv[0:15]`, `coeff[0:15]` | Already regs; 16×9 + 16×4 + 16×16 ≈ few hundred flops |
| Zigzag + LevelScale tables | 6×3 mf + scan — `case` / const ROM → LUT |
| Inv quant multiply | One 16×16 MAC; use **1 DSP** or shift-add by qp%6 |
| 4×4 IDCT | Pure add/shift butterflies; multi-cycle FSM (~8–16 cycles) |
| Intra4×4 modes 0–8 | Spec formulas; DC with hasA/hasL |
| I16 DC Hadamard | Same as host `invQuantHadamardDc4x4` (TRANSPOSE layout!) |
| Chroma 2×2 Hadamard | Small; host `invChromaDc2x2` |
| Within-MB neighbours | Left/above 4×4 of **same** MB = MB Y regs (256 B → MLAB or flops, not M10K) |
| First-MB unavailable | Outside: hasA=hasL=0 → DC=128 (no top-row RAM) |

### Must use BRAM (only for all-MB)

| Buffer | Size | M10K est | Notes |
|--------|------|----------|-------|
| Top luma row | 320 × 8 b | **1** | after each MB row |
| Top chroma U/V | 160 × 8 × 2 | **1** | 4:2:0 |
| TotalCoeff cache (nC) | ~ mb_w×4×5b × 2 rows | **≤1** | or MLAB |
| Live slice stream | **0 new** | 0 | keep reading `bitstream_fifo`; **do not** grow MAXB to whole IDR |
| Optional MB scratch | 16×16×8 | 0 | prefer regs/MLAB |

**Forbidden BRAM growth:** full-slice RBSP capture, dual YUV frame buffers, large coeff FIFOs.

---

## BRAM budget (Cyclone V 5CSEBA6)

Device: **553 M10K**, **5.66 Mbit**. Current fit: **407 / 553 (74%)**, **~3.17 Mbit (56%)**.

### Existing major consumers (approx)

| Block | Bits | ~M10K |
|-------|------|-------|
| `frame_store` 320×240×16×2 | 2,457,600 | ~240 |
| `bitstream_fifo` 32 KiB | 262,144 | ~26 |
| `audio_fifo` 2048×32 | 65,536 | ~7 |
| sys / ascal / misc | rest → 407 total | ~134 |

### Headroom

| Resource | Free now | 3.3l plan use | After 3.3l (est) |
|----------|----------|---------------|------------------|
| M10K | **146** | +0 first-MB; +2…4 all-MB | **~74–76%** |
| Block bits | ~2.5 Mbit | negligible for tables | still ≪ 100% |
| ALM | **77% free** | IDCT+pred+CAVLC walk ~1–3k ALM | ~25–30% |
| DSP | **75 free** | 0–2 for quant mul | ~33–35% |

### Risk controls if M10K creeps

1. Prefer MLAB for ≤2 Kib scratch.  
2. Never enlarge `bitstream_fifo` for decode.  
3. If neighbour rows push fit: drop chroma top-row first (luma-only paint for lab).  
4. Last resort: shrink audio DEPTH 2048→1024 (~3 M10K) — product impact, avoid.  
5. Do **not** dual-buffer YUV; RGB into existing banks only.

---

## Implementation phases

### 3.3l-0 — Host golden stubs (no FPGA) ✅

Lock math before RTL. **Done** in `tests/unit/test_idct_quant.cpp` (`make unit`).

- `dequant4x4` + `idct4x4_add` on synthetic DC and real first residual  
- First I_NxN 4×4: pred=128 (unavailable), qp=25, host coeffs → pixel golden  
- Hard-locked golden + printable dump: coeffs, dequant block, meanY, y[0..3][0..3]  
- Reuse `probeFirstI16Dc` / recon path; no new algorithm

**Locked golden (Baseline clip, first residual):**

| Field | Value |
|-------|-------|
| tc / t1 / qp | 8 / 3 / 25 |
| coeff scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| synth DC-only y | 62 (uniform; coeff0=-24) |
| y00 / mean4×4 | 73 / 62 |
| y 4×4 | `73 72 76 76` / `72 74 71 73` / `76 71 32 27` / `76 73 27 24` |

**Exit:** `make unit` includes quant/IDCT check; coeffs and 4×4 pixels known for golden clip.

### 3.3l-1 — Full first residual coeffs on FPGA (logic-only)

**Host prep (done, no Quartus):** goldens in `host/libmisterplex/h264_residual_gold.hpp`;
helpers in `h264_cavlc.hpp`; locked by `test_idct_quant`.

| Host / RTL | Value |
|------------|-------|
| coeff scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| `residualCsum8` | **20 / 0x14** = XOR of `sat_s8(coeff[i])` (host + ST_PLACE RTL) |
| Ports | `residual_coeff[0:15]` signed 9b through `stream_path`; `residual_csum[7:0]` |
| Status pack | `[103:96]=dc` `[111:104]=csum` `[127:112]=bytes[15:0]` (`Plex.sv`) |
| Host status | `push_frame` prints `res_csum=`; `CoreStatus::residual_csum` |
| Unit | `test_idct_quant` locks full-16 + csum; prints `FPGA_GOLD` lines |
| MAXB / M10K | **48** unchanged; **no new M10K** |
| RBF | ST_PLACE+status **in tree**; lab **`820484a6`** packs raw[13] live but csum **FAIL**; **R-csum1** rebuild in-flight |

Helpers: `satS8`, `residualCsum8`, `dumpResidualCoeffs`, `hostToFpgaResidualExpose`,
`residualCoeffsMatch`. Goldens: `residual_gold::{kCoeffScan,kCsum8,kDc,kY}`.

- Keep `residual_dc = satS8(coeff[0])` = **-24** for regression  
- Still **one** residual block; nC=0; MAXB=48 unchanged  

**Exit unit:** host dump == `residual_gold` (csum **0x14**, full-16). ✅  
**Exit HW (hard):** `test_f3_residual.sh` `res_dc=-24` + **hard** `res_csum=20` (soft-skip ≠ PASS).

#### HW evidence — residual csum (L-csum-note, 2026-07-24)

| Item | Result |
|------|--------|
| Host unit | XOR sat8(full-16) = **0x14** / **20** locked (`test_idct_quant`, `residual_gold::kCsum8`) |
| Prior RBF `aa146c17` | `res_dc=-24` PASS; `res_csum` FAIL (raw[13]=`0x53` ≈ stream_bytes residue) |
| Lab RBF **`820484a6`** (Q-fix1) | FBAR green; **`res_dc=-24` OK** (stable `0xE8`); **hard `res_csum=20` FAIL** |
| raw[13] on `820484a6` | **Live** (not stuck alias) but **≠0x14** and **unstable** across re-push (e.g. 239/66/149; 232/59/142) |
| Soft-skip | `test_f3_residual.sh` EXIT=0 on mismatch — **not** hard PASS |
| **R-csum1** | **In-flight** sole rebuild: running XOR + ST_PLACE `lev[]` csum fix (log `/tmp/plex_quartus_rcsum1.log`) |
| **3.3l-2 paint** | **BLOCKED** — do **not** start inv_quant/IDCT fit or `files.qip` until **hard `res_csum=20` PASS post-deploy** |

Peer reports: `/tmp/misterplex-agent-H-deploy-fix1.txt`, `/tmp/misterplex-agent-H-gate-fix1.txt`,
`/tmp/misterplex-agent-Q-fix1.txt`.

### 3.3l-2 — Inv quant + IDCT on first 4×4 (logic-only)

**Host prep (done, no Quartus):** `h264_residual_gold.hpp` locks dequant + recon paint;
`test_idct_quant` prints `FPGA_GOLD deq4x4` / `recon_y4x4` / `recon_y00` / `recon_mean`.

New small FSM after residual place (in parser or `mb_recon`):

1. `dequant4x4(coeff, max=16, qp=slice_qp±mb_qp_delta)`  
2. pred block = 128 (MB0 4×4, no neighbours)  
3. `idct4x4_add` → 4×4 recon Y  
4. Status: mean of 16 samples or y00 for eyes-on  
5. `decode_stub`: paint **top-left 4×4** (or full 16×16 if only one block) with true recon gray/RGB

**Bit-exact target vs host** for that 4×4 (mae=0 on block).

#### Locked host paint vector (Baseline first residual)

Source of truth: `host/libmisterplex/h264_residual_gold.hpp` + `tests/unit/test_idct_quant.cpp`
(`3l2-table` table-only + `3l2-real` annex-B). `make unit` locks both.

| Step | Value |
|------|-------|
| coeff scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| qp / pred | 25 / **128** (unavailable neighbours → DC) |
| residual_csum | **20 / 0x14** = XOR sat8(coeff[i]) — **not** stale arith sum **−20 / 0xEC** |
| dequant 4×4 (row-major) | `-4224 896 0 -224` / `896 -1152 0 288` / `0 0 0 0` / `-224 288 0 0` |
| recon Y 4×4 | `73 72 76 76` / `72 74 71 73` / `76 71 32 27` / `76 73 27 24` |
| y00 / mean4×4 | **73** / **62** = `(sum+8)/16` |
| paint y00 RGB565 | **0x4A49** (`grayRgb565(73)`) |
| 3.3k stub contrast | MB0 gray = `128+dc` = **104** (RGB565 **0x6B4D**) — **not** true recon |
| frame_store addrs @W=320 | `0..3, 320..323, 640..643, 960..963` |

#### `decode_stub` top-left 4×4 sketch (no Quartus this fire)

Today (`decode_stub.sv` 3.3k): when `residual_ok`, **entire MB0 16×16** is painted
`clamp(128 + residual_dc)` → gray **104**, packed RGB565 `{R[7:3],G[7:2],B[7:3]}` with R=G=B.

**3.3l-2 target paint** (logic-only, no new M10K):

```text
// After inv_quant + idct_add onto pred=128 → recon_y[0:3][0:3] = residual_gold::kY
// Sequential paint (existing wr_en / wr_pixel / wr_reset_ptr path):
//   for y in 0..239:
//     for x in 0..319:
//       if (x < 4 && y < 4 && lat_res_ok && recon_ready)
//         wr_pixel = gray_rgb565(recon_y[y][x]);   // true 4×4
//       else if (mb0 && lat_res_ok)
//         // optional: leave rest of MB0 as diagnostic grid / stub 104 / or 128
//         ...
// frame_store linear addrs for top-left 4×4 @ W=320:
//   0,1,2,3, 320,321,322,323, 640..643, 960..963
// y00 RGB565 = grayRgb565(73)  (host residual_gold::kPaintY00Rgb565)
```

**Minimal RTL add** (prefer regs only):

| Item | Notes |
|------|-------|
| Hold `coeff[0:15]` after ST_PLACE | already 3.3l-1 tree |
| `inv_quant4` + `idct4x4` FSM | multi-cycle; match host butterflies |
| `recon_y[0:3][0:3]` 16×8b regs | paint source |
| `recon_ready` sticky | gate paint vs incomplete IDCT |
| Status soft | `recon_y00=73`, `recon_mean=62`; **keep `res_dc=-24`** |

Do **not** require full MB0 true recon in 3.3l-2 — only first coded 4×4 (scan block 0).
Rest of frame may stay strip/MB-grid diagnostic.

**Exit unit:** `test_idct_quant` locks deq + y[][] + paint contract (stub 104 ≠ y00 73).  
**Exit HW:** `tests/hw/test_f3_idct_mb0.sh` — residual gates + recon mean/y00 match host golden.

---

### Post-hard-csum checklist (next RTL agent — short)

> **HARD GATE — do not start inv_quant / IDCT fit, SV wire-up, or `files.qip` until
> lab hard PASS: `res_csum=20` after R-csum1 (or successor) BUILD_OK + sole deploy + FBAR green.**  
> Keep `res_dc=-24`. Lab **`820484a6`** (post Q-fix1): `res_dc=-24` OK but **hard `res_csum` FAIL**
> (raw[13] live, unstable, ≠ `0x14`). Host unit XOR still locked **0x14**.  
> R-csum1 owns running-XOR + ST_PLACE `lev[]` csum fix; paint path must not thrash residual status.

**Handoffs (read, do not re-derive):**
- **L-3l2e** host goldens DONE — `/tmp/misterplex-agent-L-3l2e.txt`
- **L-3l2-rtl** plug sketch DONE (docs only, no SV) — `/tmp/misterplex-agent-L-3l2-rtl.txt`  
  + section *3.3l-2 concrete RTL plug sketch* below

**Inputs already in tree (3.3l-1):** `residual_coeff[0:15]` signed 9b from
`slice_hdr_parser` ST_PLACE → `stream_path` (keep wire; do not recompute csum/dc).

**Host paint goldens (must match mae=0):**

| Field | Value |
|-------|-------|
| `residual_coeff` scan | `-24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0` |
| res_csum | **20 / 0x14** (XOR sat8 — never arith −20 / 0xEC) |
| pred / qp | **128** / **25** |
| y00 / mean4×4 | **73** / **62** |
| paint y00 RGB565 | **0x4a49** (`grayRgb565(73)`) |
| stub contrast | y=104 RGB565 **0x6B4D** (128+dc — not true recon) |

SoT: `host/libmisterplex/h264_residual_gold.hpp` + `tests/unit/test_idct_quant.cpp`
(`FPGA_GOLD … recon_y00=73 recon_mean4x4=62 paint_y00_rgb565=0x4a49`). Full deq/Y
tables in *Locked host paint vector* above.

#### After gate green — paint steps (logic-only, **no new M10K**)

1. Consume **`residual_coeff[0:15]`** + `slice_qp` (25); trigger on `residual_ok`.  
2. **`inv_quant4`** = host `dequant4x4` → match `kDeq` (deq00=-4224).  
3. **`idct4x4_add`** onto pred=128 → match `kY` (y00=73 mean=62).  
4. **`decode_stub`:** when `recon_ready`, paint **top-left 4×4 only** (`0x4a49` at addr 0);
   rest of MB0 may stay stub 104. frame_store @W=320: `0..3, 320..323, 640..643, 960..963`.  
5. Soft telem optional: `recon_y00=73`, `recon_mean=62`. **Hard keep** res_dc/csum/ok/tc/t1.  
6. Sole Quartus only when fit slot free (`NUM_PARALLEL=2`); never mid-FBAR thrash.  
   Detail interfaces: *L-3l2-rtl* section below.

#### HW gates after paint RBF

| Step | Gate | Pass when |
|------|------|-----------|
| Residual | `test_f3_residual.sh` | hard `res_dc=-24` + hard `res_csum=20` |
| IDCT/paint | `test_f3_idct_mb0.sh` | residual hard; soft→hard y00=73 / mean=62; eyes-on ≠104 |
| FBAR | `test_fbar_fast` | still green |

#### Non-goals (3.3l-2 paint)

- Full MB0 / all MBs (3.3l-3/4) · MAXB/FIFO/dual-YUV BRAM · hybrid present  
- Half-wiring inv_quant/idct into `files.qip` **before** hard `res_csum=20`  
- Second Quartus while Q-fix1 (or any fit) is live

---

### 3.3l-2 concrete RTL plug sketch (L-3l2-rtl — docs only; no fit)

**Gate still open (do not start paint Quartus):** lab RBF **`820484a6`** has
`res_dc=-24` PASS but **`res_csum=20` FAIL** (raw[13] live / unstable, never XOR
`0x14`; earlier `aa146c17` raw[13]=`0x53` stream-bytes residue). Host unit locked
XOR sat8 full-16 = **0x14**. Tree `Plex.sv` assigns `status_telem[111:104]=residual_csum`
— **R-csum1** owns running XOR + ST_PLACE `lev[]` fix (in-flight). Until hard
residual is green post-deploy, paint RTL stays sketch-only.

Report: `/tmp/misterplex-agent-L-3l2-rtl.txt`. Host SoT unchanged (L-3l2e).

#### Where modules plug (tree as of L-3l2-rtl)

```text
slice_hdr_parser.sv  ST_PLACE
    residual_ok, residual_dc, residual_csum
    residual_coeff[0:15] signed [8:0]   (*keep*)
         │
         ▼
stream_path.sv
    passes residual_* straight out
    decode_stub today: residual_ok/tc/dc only  ← NO coeff yet
         │
         ├─ (today)  decode_stub MB0 gray = clamp(128+dc) = 104
         │
         └─ (3.3l-2 target)
              residual_coeff[0:15] + slice_qp ──► inv_quant4
                                                    │ deq[4][4]
                                                    ▼
                                                 idct4x4_add (pred=128)
                                                    │ recon_y[4][4]
                                                    ▼
                                                 decode_stub top-left 4×4 paint
                                                    RGB565 gray pack
```

| Port / reg | Source today | Consumer 3.3l-2 |
|------------|--------------|-----------------|
| `residual_coeff[0:15]` signed 9b | `slice_hdr_parser` ST_PLACE → `stream_path` out | **`inv_quant4` input** (scan order) |
| `slice_qp` [5:0] | `slice_hdr_parser` (Baseline first MB: **25**) | **`inv_quant4` qp** |
| `residual_ok` | ST_PLACE sticky | start recon FSM; keep for paint gate |
| `residual_dc` / `residual_csum` | ST_PLACE | **status only** — do not recompute in paint path |
| `recon_y[0:3][0:3]` 8b | new regs after IDCT | `decode_stub` top-left 4×4 |
| `recon_ready` | new sticky | gate paint vs incomplete IDCT |
| `fs_wr_*` | `decode_stub` → `frame_store` | unchanged bus; pixel source changes for x&lt;4,y&lt;4 |

#### Module interfaces (sketch — not in `files.qip`)

**`inv_quant4`** — match `recon::detail_r::dequant4x4` (`h264_recon.hpp`):

```text
inputs:  clk, reset, start, qp[5:0], coeff[0:15] signed [8:0]  (or [15:0])
outputs: busy, done, blk[0:3][0:3] signed [15:0]   // residual domain, row-major
tables:  kZigzag = {0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15}
         kNormAdjust[6][3] = {{10,13,16},{11,14,18},{13,16,20},{14,18,23},{16,20,25},{18,23,29}}
math:    shift = qp/6 + 2
         mi = (i&1)+(j&1) → 0 even/even, 1 one-odd, 2 both-odd
         qmul = (kNormAdjust[qp%6][mi] * 16) << shift
         blk[i][j] = (level * qmul + 32) >> 6
         maxCoeff=16 for first luma residual (use zigzag[k], not k+1)
cycle:   1 start → clear blk; then 0..15 sequential (skip zero levels) or combo if ALM OK
gold:    residual_gold::kDeq  (qp=25, kCoeffScan)  deq00=-4224
```

**`idct4x4_add`** — match `ff_h264_idct_add` / host `idct4x4_add`:

```text
inputs:  clk, reset, start, blk[0:3][0:3] signed [15:0], pred_fill=8'd128 (or pred[16])
outputs: busy, done, recon_y[0:3][0:3] [7:0]
steps:   1) b = blk; b[0][0] += 32
         2) 4 horizontal butterflies (rows)
         3) 4 vertical butterflies (cols); clip8(pred + (z>>6))
multi-cycle FSM (~8–16 cycles); pure add/shift — **no new M10K, 0 DSP required**
gold:    residual_gold::kY  y00=73 mean=(sum+8)/16=62
```

**Optional thin `mb_recon4` wrapper** (or inline in `stream_path`):

```text
on residual_ok rise + coeffs stable:
  inv_quant4.start → wait done
  idct4x4_add.start (pred=128) → wait done → recon_ready=1
  recon_y00 = recon_y[0][0]; recon_mean = (sum+8)/16
```

#### `stream_path` / `decode_stub` wire-up plan (when unblocked)

1. **Instantiate** `inv_quant4` + `idct4x4_add` in `stream_path.sv` (next to `decode_stub`), **not** inside `slice_hdr_parser` (keep CAVLC place pure).  
2. Feed `residual_coeff` + `slice_qp` (`sl_qp`) into inv_quant; trigger on `sl_res_ok` rising edge after ST_PLACE.  
3. Extend `decode_stub` ports:

```text
// add (when wiring):
input wire        recon_ready,
input wire [7:0]  recon_y00,          // optional status mirror
input wire [7:0]  recon_y [0:15],     // row-major 4×4  OR  recon_y[0:3][0:3]
// paint:
//   if (x < 4 && y < 4 && lat_res_ok && lat_recon_ready)
//     gray = recon_y[y*4+x];          // true 4×4 — y00=73
//   else if (mb0 && lat_res_ok)
//     gray = clamp(128+lat_res_dc);   // rest of MB0 stub 104 OK
// RGB565: {R[7:3],G[7:2],B[7:3]} R=G=B
// frame_store @W=320: addrs 0..3, 320..323, 640..643, 960..963
```

4. **Do not** touch `residual_dc` / `residual_csum` packing in `Plex.sv` from paint work — leave R-csum1 (csum fix) sole owner of residual status until green.  
5. Soft telem (optional later): spare status bytes for `recon_y00`/`recon_mean`; hard residual fields stay.  
6. `files.qip`: add `rtl/inv_quant4.sv` + `rtl/idct4x4_add.sv` **only** when sole paint fit starts **after** hard csum PASS.

#### Implementation order (after hard res_csum=20)

| Step | Action | Verify |
|------|--------|--------|
| 0 | **R-csum1** (or successor) deploy → hard `res_csum=20` on HW | `test_f3_residual.sh` hard |
| 1 | Add `inv_quant4.sv` + unit-sim or table ROM vs `kDeq` (optional host C++ already locks) | deq match |
| 2 | Add `idct4x4_add.sv`; pred=128 → `kY` | y00=73 mean=62 |
| 3 | Wire in `stream_path`; extend `decode_stub` paint | no residual bus thrash |
| 4 | Sole Quartus (`NUM_PARALLEL=2`); one deploy | FBAR green |
| 5 | `test_f3_idct_mb0.sh` residual hard + recon soft→hard | y00≠104 eyes-on |

#### Resource / fit notes (unchanged budget)

- Logic-only: 16×9 coeff already present; +16×16 deq regs; +16×8 recon_y; small FSM.  
- **No new M10K.** Optional 1 DSP for quant mul or pure shift-add.  
- Current fit headroom: ALM ~78% free; M10K tight at 74% — do not grow FIFO/MAXB.  
- Prefer **not** checking in orphan SV until step 1 of paint fit (avoids accidental `files.qip` thrash).

#### Hard gate reminder

```text
BLOCKED:  res_csum hard = 20 (0x14 XOR) on lab after R-csum1 (or successor) deploy
LAB NOW:  RBF 820484a6 — res_dc=-24 OK; raw[13] live but ≠0x14 (unstable) FAIL
HOST:     XOR sat8 full-16 = 0x14 locked unit; y00=73/mean=62/paint 0x4a49
IN-FLIGHT: R-csum1 running XOR + ST_PLACE lev[] csum fix
THEN:      Post-hard-csum checklist (above) → paint RTL steps; never mid-FBAR thrash
NO FIT:   inv_quant/IDCT / 3l2 paint until lab res_csum=20 hard PASS post-deploy
```

### 3.3l-3 — First full MB (I_NxN or I16)

Golden clip is **I_NxN** (`mb0=0`):

1. Parse 16× I4 pred mode (already skipped in ST_I4MODE — **retain modes**)  
2. CBP + mb_qp_delta (done)  
3. For each coded 4×4 in scan order: CAVLC(nC), dequant, predI4, idct-add  
4. Within-MB nC from left/above TC (regs)  
5. Chroma: pred + DC/AC residual (host order)  
6. Pack MB → RGB565; stub paints **MB0 only** correctly; rest of frame diagnostic grid OK  

**Capture limit:** first full MB residual body may exceed 48 B.

| Option | Pros | Cons |
|--------|------|------|
| A. Raise MAXB 48→128/256 (regs) | Minimal rewire | ALM/reg; still not full slice |
| B. Stream bit-walker past cap | Scales to all-MB | More work; preferred long-term |

**Plan:** 3.3l-3 may use **MAXB=128** (regs, ~1 Kib — still not M10K) as bridge; 3.3l-4 switches to streaming.

**Exit:** host vs FPGA mae on MB0 Y (16×16) = 0; chroma optional same fire or +1.

### 3.3l-4 — All MBs (I-slice)

1. **Streaming residual path:** after headers, consume bits from live FIFO (or long window), not fixed 48 B only.  
2. Neighbour **top row** M10K (+ chroma).  
3. Left column + TC from previous MB (regs).  
4. Loop mbx,mby to `sps_mb_w × sps_mb_h` (20×15 @ 320×240).  
5. Per MB: write 16×16 Y (+ chroma) → convert RGB565 → `frame_store` sequential or addressed paint.  
6. `decode_stub` becomes thin: kick recon engine, wait done, swap.  
7. Status: `mb_done`, `recon_ok`, fail_mb (if any).  

**Out of scope this phase:** P-slice / motion / CABAC / deblock (optional later; host already skips LF for gold).

**Exit:** full frame maeY≈0 vs host/FFmpeg no-LF on golden 320×240 IDR; `host_owns_fs` still preferred for product until soak.

### 3.3l-5 — Hybrid gate (product)

Only when 3.3l-4 mae competitive on lab titles:

- Allow STREAM path to skip host F1 recon when FPGA `recon_ok`  
- Keep host fallback on CABAC / fail  
- Measure: ALM/M10K fit, decode latency vs present 30 fps budget  

---

## RTL notes (match host / FFmpeg)

### Inv quant (`dequant4x4`)

```text
qmul = (mf[qp%6][pos] * 16) << (qp/6 + 2)
blk[i][j] = (level * qmul + 32) >> 6
zigzag: {0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15}
maxCoeff=15 → skip scan DC slot (I16 AC / chroma AC)
```

### IDCT (`idct4x4_add`)

- `block[0][0] += 32` before butterflies  
- Horizontal then vertical; `(x)>>6` add into pred; clip 0..255  
- Multi-cycle OK; no need one-cycle combo path  

### Intra I4

- MPM / rem already in bitstream (parser must **store** modes in 3.3l-3)  
- Unavailable neighbour → mode forced DC(2) where host does  
- Top-right sample rules: `lumaReady` / replicate above[3] (3.3h lessons)  

### I16 DC

- Hadamard input layout: CAVLC zigzag then **FFmpeg TRANSPOSE** before butterfly  
- Host: `invQuantHadamardDc4x4` — copy exactly or mae will fail  

### First MB availability

| Sample | First MB (0,0) |
|--------|----------------|
| Above / left / TL | unavailable → 128 for DC |
| Top-right outside pic | replicate |

---

## Status / telemetry sketch

Keep existing residual fields. Add without breaking `push_frame --status` parsers more than needed:

| Bits / field | Meaning |
|--------------|---------|
| existing res_* / res_dc | regression 3.3k |
| **`[111:104] residual_csum8`** | **3.3l-1** XOR sat8(coeff[0:15]); host `res_csum=` (gold **20**/0x14) |
| `[127:112] stream_bytes[15:0]` | after 3.3l-1 (was 24b in [127:104]) |
| `recon_y00` or mean4×4 | 3.3l-2 eyes-on — host gold **y00=73 mean=62** (`residual_gold`) |
| `mb_done[7:0]` | 3.3l-4 progress |
| `recon_ok` sticky | full I-slice done |

Host already parses `residual_csum` from raw[13] (soft until RBF). Document assign in `Plex.sv` when RTL lands.

---

## Tests

| Milestone | Unit | HW |
|-----------|------|-----|
| 3.3l-0 | `test_idct_quant` / extend `test_cavlc_dc` | — |
| 3.3l-1 | host `h264_residual_gold` coeff[16]+csum=0x14 | `test_f3_residual.sh` res_dc; soft res_csum=20 after RBF |
| 3.3l-2 | `test_idct_quant` paint/deq goldens + `FPGA_GOLD recon_*` | `tests/hw/test_f3_idct_mb0.sh` residual hard; soft→hard y00=73 mean=62 |
| 3.3l-3 | MB0 Y mae=0 | HW status + optional frame dump |
| 3.3l-4 | full recon maeY=U=V=0 | `test_f3_recon_frame.sh` vs host RGB/YUV |
| Hybrid | — | STREAM smoke; host_owns_fs policy |

Do **not** require Quartus for 3.3l-0. Fit check only when RTL lands (sole build, `NUM_PARALLEL=2`).

---

## Milestone checklist (summary)

1. **3.3l-0** ✅ Host quant/IDCT golden + first-4×4 pixel vector (`test_idct_quant`)  
2. **3.3l-1** Host gold+status ✅ (XOR sat8 full-16 **0x14**/20); lab `820484a6` `res_dc=-24` OK, **hard csum FAIL** (raw[13] live/unstable); **R-csum1 in-flight**  
3. **3.3l-2** Host paint goldens + post-3l1 handoff ✅ (y00=73 mean=62 pred=128; HW script ready); **RTL plug sketch ✅** (L-3l2-rtl docs; no SV/`files.qip`); paint fit **blocked** until hard `res_csum=20` **PASS post-deploy**  


4. **3.3l-3** First full MB (I_NxN modes+CBP+16× residual+chroma); MAXB bridge or stream start  
5. **3.3l-4** All MBs + top-row BRAM + stream CAVLC; full-frame mae  
6. **3.3l-5** Product hybrid gate when mae competitive  

---

## Non-goals (3.3l)

- Deblocking filter  
- P/B slices, motion compensation  
- CABAC  
- Resolutions above current 320×240 bring-up (scale after mae@320)  
- Replacing host F1 before 3.3l-5  
- Growing bitstream FIFO or dual YUV M10K framebuffers  

## References in tree

- Residual FSM: `fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv`  
- Paint: `fpga/Plex_MiSTer/rtl/decode_stub.sv`  
- Wire-up: `fpga/Plex_MiSTer/rtl/stream_path.sv`  
- Host gold: `host/libmisterplex/h264_recon.hpp`, `h264_cavlc.hpp`, `h264_residual_gold.hpp`  
- Unit paint/IDCT: `tests/unit/test_idct_quant.cpp` (`FPGA_GOLD recon_*`)  
- HW residual: `tests/hw/test_f3_residual.sh`  
- HW paint gate: `tests/hw/test_f3_idct_mb0.sh` (host contract y00=73 mean=62; soft until paint RBF)  
- Post-3l1 handoff: section above in this doc  
- Parent log: `docs/phase3-decode.md` (Phase 3.3k → 3.3l pointer)
