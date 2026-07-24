# Phase 3.3l — Inv quant + 4×4 IDCT + Intra pred (FPGA)

**Status:** 3.3l-0 done; 3.3l-1 **RTL+host ready-for-fit** (full-16 + csum=0x14; Q-3l1 sole fit); 3.3l-2 **host paint goldens + post-3l1 handoff DONE** (y00=73 mean=62 pred=128; `test_f3_idct_mb0.sh`); RTL inv_quant/IDCT paint open after 3l1 RBF green  

**Depends on:** 3.3k residual levels/runs → `residual_dc` (HW-green)  
**Product rule:** hybrid host recon → F1 still owns present until FPGA mae is competitive.  
**No Quartus for 3.3l-0 / host 3.3l-1 / host 3.3l-2** — RTL/fit when sole build free (leave Q-3l1 alone).

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
| RBF | ST_PLACE+status **in tree** — **need sole fit after FBAR** (no Quartus this fire) |

Helpers: `satS8`, `residualCsum8`, `dumpResidualCoeffs`, `hostToFpgaResidualExpose`,
`residualCoeffsMatch`. Goldens: `residual_gold::{kCoeffScan,kCsum8,kDc,kY}`.

- Keep `residual_dc = satS8(coeff[0])` = **-24** for regression  
- Still **one** residual block; nC=0; MAXB=48 unchanged  

**Exit unit:** host dump == `residual_gold` (csum **0x14**, full-16).  
**Exit HW (after 3.3l-1 RBF):** `test_f3_residual.sh` `res_dc=-24` + soft `res_csum=20`.

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

### Post-3l1 RBF → 3.3l-2 paint handoff (host DONE; RTL next)

**Host handoff finalized (L-3l2e):** goldens locked **y00=73 mean=62 csum=0x14/20**
(XOR sat8; not arith −20/0xEC). Unit `test_idct_quant` EXIT=0 (`3l2-table`+`3l2-real`).
Report `/tmp/misterplex-agent-L-3l2e.txt`. **No further host re-derive needed.**

**When:** sole Q-3l1 rebuild `BUILD_OK`, one deploy, FBAR retest green, and
`test_f3_residual.sh` hard-gates `res_dc=-24` **+** `res_csum=20` (XOR 0x14).

**Do not start 3.3l-2 RTL fit before that residual csum hard-gate is green.**

#### Host source of truth (no re-derive)

| Artifact | Path / command |
|----------|----------------|
| Compile-time goldens | `host/libmisterplex/h264_residual_gold.hpp` |
| Unit lock | `tests/unit/test_idct_quant.cpp` (`3l2-table` + `3l2-real`) |
| Run | `./build/test_idct_quant /tmp/plex_real_baseline.h264` (or `make unit`) |
| Machine lines | `FPGA_GOLD pred=128` … `recon_y00=73 recon_mean4x4=62 paint_y00_rgb565=0x4a49` |
| Clip | `scripts/gen_test_annexb_real.py` → Baseline F3 first residual |

#### Locked paint contract (must match mae=0)

```text
pred = 128                    # first 4×4 unavailable neighbours → DC
qp   = 25
coeff_scan = -24 4 4 0 -4 0 -1 0 0 -1 1 0 1 0 0 0
res_csum   = 20 (0x14)        # XOR sat8 — NEVER -20 / 0xEC
deq 4×4    = -4224 896 0 -224 / 896 -1152 0 288 / 0 0 0 0 / -224 288 0 0
recon Y    = 73 72 76 76 / 72 74 71 73 / 76 71 32 27 / 76 73 27 24
y00=73  mean4x4=62=(sum+8)/16
paint y00 RGB565 = 0x4A49    # gray pack {R[7:3],G[7:2],B[7:3]} R=G=B=73
stub contrast    = y=104 RGB565 0x6B4D   # 128+dc; NOT true recon
frame_store @W=320: 0..3, 320..323, 640..643, 960..963
```

#### RTL agent checklist (logic-only, **no new M10K**)

1. Consume `residual_coeff[0:15]` already placed by 3.3l-1 `ST_PLACE` (keep wire).  
2. `inv_quant4` = host `dequant4x4` (zigzag + LevelScale; qp=25). Match `kDeq`.  
3. Fill `pred[16]=128`; run multi-cycle `idct4x4_add` = FFmpeg/`h264_recon.hpp`. Match `kY`.  
4. `decode_stub`: when `recon_ready`, paint **top-left 4×4 only** from `recon_y[][]`
   (rest of MB0 may stay stub 104 / grid).  
5. Soft status (optional spare bytes): `recon_y00=73`, `recon_mean=62`.  
6. **Hard keep:** `res_dc=-24`, `res_csum=20`, `res_ok/tc/t1`. Do not thrash residual bus.  
7. Sole Quartus only when fit slot free (`NUM_PARALLEL=2`); never mid-FBAR thrash.

#### HW gate sequence after paint RBF

| Step | Gate | Notes |
|------|------|-------|
| Residual | `test_f3_residual.sh` | hard `res_dc=-24` + hard `res_csum=20` |
| IDCT/paint | `test_f3_idct_mb0.sh` | residual hard; soft→hard `recon_y00=73` / `recon_mean=62` when telem packs; eyes-on y00≠104 |
| FBAR | `test_fbar_fast` | must stay green after any paint RBF |

#### Non-goals for 3.3l-2 paint

- Full MB0 / all MBs (that is 3.3l-3/4)  
- Changing MAXB / bitstream_fifo / dual YUV BRAM  
- Product hybrid present (`host_owns_fs` stays until 3.3l-5)  
- Re-fitting while another Quartus is live  

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
2. **3.3l-1** Host gold+status ✅ (`csum=0x14`/20); RTL ST_PLACE+status pack in tree — need fit/RBF; keep `res_dc=-24`  
3. **3.3l-2** Host paint goldens + post-3l1 handoff ✅ (y00=73 mean=62 pred=128; HW script ready); RTL inv quant + IDCT + DC-pred paint; HW gate after paint RBF  

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
