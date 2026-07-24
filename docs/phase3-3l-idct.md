# Phase 3.3l — Inv quant + 4×4 IDCT + Intra pred (FPGA)

**Status:** plan (not implemented)  
**Depends on:** 3.3k residual levels/runs → `residual_dc` (HW-green)  
**Product rule:** hybrid host recon → F1 still owns present until FPGA mae is competitive.  
**No Quartus in this doc phase** — implement RTL/host tests first; fit when ready.

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
| Fit (5CSEBA6, post-3.3k) | ALM **23%** (9.4k/41.9k), M10K **74%** (407/553), bits 56%, DSP 33% | headroom: **ALM**, **DSP**; **M10K is tight** |

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

### 3.3l-0 — Host golden stubs (no FPGA)

Lock math before RTL.

- Unit: `tests/unit/test_idct_quant.cpp` (optional, small)  
  - `dequant4x4` + `idct4x4_add` on synthetic and real first residual  
  - First I_NxN 4×4: pred=128 (unavailable), qp=25, host coeffs → pixel golden  
  - Export printable golden: meanY, y[0..3][0..3] for HW status compare  
- Reuse `probeFirstI16Dc` / recon path; no new algorithm.

**Exit:** `make unit` includes quant/IDCT check; coeffs and 4×4 pixels known for golden clip.

### 3.3l-1 — Full first residual coeffs on FPGA (logic-only)

Extend `ST_PLACE` in `slice_hdr_parser`:

- Build `coeff[0:15]` signed (scan order), not only `coeff[0]`  
- Keep `residual_dc = coeff[0]` for regression  
- Status (example): pack `coeff[1]` or checksum of 16 levels into spare telemetry if room  
- Still **one** residual block; nC=0; MAXB=48 unchanged  

**Exit HW:** `test_f3_residual.sh` still green (`res_dc=-24`); optional `res_csum=` matches host.

### 3.3l-2 — Inv quant + IDCT on first 4×4 (logic-only)

New small FSM after residual place (in parser or `mb_recon`):

1. `dequant4x4(coeff, max=16, qp=slice_qp±mb_qp_delta)`  
2. pred block = 128 (MB0 4×4, no neighbours)  
3. `idct4x4_add` → 4×4 recon Y  
4. Status: mean of 16 samples or y00 for eyes-on  
5. `decode_stub`: paint **top-left 4×4** (or full 16×16 if only one block) with true recon gray/RGB

**Bit-exact target vs host** for that 4×4 (mae=0 on block).

**Exit HW:** new `tests/hw/test_f3_idct_mb0.sh` — residual gates + recon mean/y00 match host golden.

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
| `recon_y00` or mean4×4 | 3.3l-2 eyes-on |
| `mb_done[7:0]` | 3.3l-4 progress |
| `recon_ok` sticky | full I-slice done |

Prefer packing into unused status_telem lanes; document in `Plex.sv` comment block.

---

## Tests

| Milestone | Unit | HW |
|-----------|------|-----|
| 3.3l-0 | `test_idct_quant` / extend `test_cavlc_dc` | — |
| 3.3l-1 | host coeff dump == FPGA csum | `test_f3_residual.sh` still green |
| 3.3l-2 | 4×4 pixels vs host | `test_f3_idct_mb0.sh` |
| 3.3l-3 | MB0 Y mae=0 | HW status + optional frame dump |
| 3.3l-4 | full recon maeY=U=V=0 | `test_f3_recon_frame.sh` vs host RGB/YUV |
| Hybrid | — | STREAM smoke; host_owns_fs policy |

Do **not** require Quartus for 3.3l-0. Fit check only when RTL lands (sole build, `NUM_PARALLEL=2`).

---

## Milestone checklist (summary)

1. **3.3l-0** Host quant/IDCT golden + first-4×4 pixel vector  
2. **3.3l-1** FPGA full 16-coeff place; keep `res_dc=-24`  
3. **3.3l-2** Inv quant + IDCT + DC-pred; paint true 4×4; HW gate  
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
- Host gold: `host/libmisterplex/h264_recon.hpp`, `h264_cavlc.hpp`  
- HW residual: `tests/hw/test_f3_residual.sh`  
- Parent log: `docs/phase3-decode.md` (Phase 3.3k → 3.3l pointer)
