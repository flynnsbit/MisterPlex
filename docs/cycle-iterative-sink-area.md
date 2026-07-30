# Cycle-iterative sink redesign brief (implementable)

> **STATUS 2026-07-30 (coord-map-cf6842a, PROVISIONAL):** serial IQ **mapped**.  
> sink **DSP 4 ≤ 12 PASS** · sink **comb 39,155 (self 23,211) ALM-GATE MISS** · whole **61,267 ALMs / 111 DSP / 3,063,245 bits**.  
> Serial dequant/had **not pruned** (u_dq DSP=2, u_had DSP=2). Planes/top_row still **0 M10K bits**.  
> ALM remaining wall: sink self + intra16 pred (10,643 comb) — not the mul farm.  
> Full table: `docs/coord-map-cf6842a-ALMS.txt`. Correctness@cf6842a still owed by implementer.


**Module:** `h264_i_res_recon_sink.sv` (+ shared `h264_iq_idct_4x4.sv`, pred units)  
**Evidence:** map2d sink **40,439 comb / 64 DSP** · map3b sink **40,456 comb / 92 DSP** ·  
I16 pred **~9k** · dequant child **52 DSP** · hadamard **32 DSP** · chroma8x8 in-sink **3,859**.  
**Device:** 41,910 ALMs · **112 DSP** · product already **74 DSP**.  
**Targets after redesign:** **≤ 4,000 ALMs · ≤ 12 DSP** · M10K tops/plane as below.

**Language:** map entity counts are **comb ALUTs**; targets are **map ALMs needed** / post-fit ALMs.  
Synthesis of the oversized design **succeeds** — it **does not fit**.  
**Trap:** `(* ramstyle="M10K" *)` on plane/top without single-ported registered access will **not** infer (same lesson as traverse RBSP).

---

## 0. Ownership recommendation (for parent assignment)

| Role | Who | Why |
|------|-----|-----|
| **Implement sink.sv crash-diet** | **`sv-traverse`** | Owns the file, I-luma 300/300, `res_blk_*` contract with traverse, plane writeback |
| **Chroma behaviour / ports** | **`sv-mvd` via labelled patch only** | Leaves are already cheap; must not dual-edit sink during diet. Patch notes for TL snapshot / chroma mode only |
| **Serial IQ primitive** | **`sv-integrate` specifies here; traverse lands (or apply integrate patch)** | IQ is shared infrastructure; one serial unit must replace parallel mul trees for product stub and sink |
| **Map / ALM-DSP-M10K gate** | **`sv-integrate` only** | No competing Quartus |
| **Not** | two lanes in one file | Parent assigns one implementer after this brief |

**One line:** assign **sink implementation to `sv-traverse`**; **serial IQ design + map gate to `sv-integrate`**; **`sv-mvd` stays off `h264_i_res_recon_sink.sv`** except a patch file if chroma ports need tweaks after diet.

---

## 1. Why DSP is the real gate (front and centre)

```
product DSP     74
sink path DSP   92   (map3b entity column)
stacked        166  >  112 device
```

Even a **0 ALM traverse** cannot ship if sink keeps parallel IQ.

**Quoted cause in `h264_dequant4x4`:** combinational **16+15 parallel** `dequant_one()` paths (max16 and max15 both fully built), each `coeff * qmul` → DSP.  
**Hadamard:** wide mul plane → **32 DSP** in map3b.  
**Drift 64→92:** more of that tree kept when chroma/had/keep change — **do not plan on the transient number; plan on serial ≤12.**

ALMs can wait on cycles. **DSP cannot.**

---

## 2. Serial IQ — concrete design (the DSP fix)

### 2.1 Replace parallel dequant with one lane

**Suggested module:** `h264_dequant4x4_serial` (new file; keeps old combo module for sim golden until swapped).

```text
inputs:  clk, reset, start, qp, max_coeff, coeff[0:15] (capture on start)
outputs: busy, done, dequant[0:15] (regs filled over 16 cycles)

cycle k = 0..15:
  dequant_q[zigzag_dest(k, max_coeff)] <= dequant_one(coeff[k], qp, ...)
cycle 16: done=1
```

- **One** multiplier (or shift-add for `norm_adjust*16 << qdiv`).  
- Target **0–2 DSP** for dequant.  
- max15 vs max16 = **mux on destination index**, not a second mul farm.

### 2.2 IDCT

`h264_idct4x4` ~1.9k comb, **0 DSP** — keep 4×4 combo or 8-cycle row/col if ALMs bite. **DSP priority is dequant+had.**

### 2.3 Hadamard DSP cut

| Unit | Now | Target |
|------|-----|--------|
| `h264_i16_dc_hadamard` | ~1.5k + **32 DSP** | butterflies + one scale lane, **≤ 2 DSP**, or shift-add |
| `h264_chroma_dc_hadamard_inv` | 249 + **8 DSP** | 2×2 + scale; **≤ 1 DSP** or shift-add |

### 2.4 Single shared IQ in sink

```text
ST_IQ:   start dequant_serial; wait done
ST_IDCT: residual_q[0:15] <= idct(dequant_q)
ST_RECON: for pi=0..15: plane[addr(pi)] <= Clip1(pred_q[pi]+residual_q[pi])  // 16 cy
```

No separate luma/chroma dequant instances.

### 2.5 Product stub

Product maps **~32 DSP** on parallel dequant today. When sink is real:

1. Stub shares the **same serial IQ**, or  
2. Stub drops IQ once sink feeds recon.

Stacked DSP must map **≤ 100** whole chip.

### 2.6 Cycle cost

Dequant 16 + IDCT 1–8 + recon 16 ≈ **33–40 cy / 4×4**.  
Full I-MB still **≪ 2000 cy** (320×240 @ 50 MHz budget).

---

## 3. ALM crash-diet (planes / neighbors / pred)

### 3.1 Forbidden pattern

```systemverilog
always @(*) begin
  i4_above[t] = plane_y[(y0-1)*16 + (x0+t)];
  i16_above[t] = top_row[mb_x*16 + t];
end
```

### 3.2 Required

```text
ST_NB_FETCH: t=0..N-1: addr<=...; next cy above[t]<=ram_q
```

| Array | Implementation |
|-------|----------------|
| `top_row` | M10K, **MAX_PIC_W=320** in product |
| `top_u/v` | M10K, depth 160 |
| `plane_*` | single-port M10K or regs; no combo multi-index |
| `write_*` | serial fill on mb_end |

### 3.3 I16 pred (~9k comb)

Do not emit combo `pred[0:255]` into recon.  
**One pixel or one row per cycle** into plane RAM (DC/H/V/Plane).

I4 at ~1.4k may stay if NB fetch is registered.

### 3.4 Chroma pred

In-sink **3,859** ALMs — OK as **one** instance (leaf-only was 690).  
Neighbors registered; tops width 320.

---

## 4. State machine sketch

```text
ST_IDLE → ST_NB_FETCH → ST_PRED → ST_IQ → ST_IDCT → ST_RECON_PX → ST_IDLE
res_mb_end → ST_WB_TOPS → write_req
```

`res_blk_ready` low when not IDLE (existing backpressure).

---

## 5. Targets and gates

| Metric | map3b now | Gate |
|--------|-----------|------|
| Sink comb | 40,456 | **≤ 4,000** |
| Sink DSP | 92 | **≤ 12** |
| Chip DSP w/ product | 154 | **≤ 100** |
| MAX_PIC_W product | 1024 default | **320** |
| Functional | 300/300 class | **no regress** |
| Tops+plane M10K add | — | **≤ ~20k bits** |

Pre-register next sink map: **2.5–4.0k ALMs**, **6–12 DSP**.  
Integrate publishes HIT/MISS from one `quartus_map` on the freeze SHA.

---

## 6. Implementer checklist (`sv-traverse`)

1. No new parallelism to “save cycles.”  
2. Serial dequant; delete parallel m15/m16 mul farms.  
3. Hadamard ≤2 DSP.  
4. Registered NB fetch; M10K tops @ 320.  
5. Serial I16 pred into plane.  
6. One chroma8x8 instance.  
7. Keep `res_blk_*` / `write_*` / `drain_idle`.  
8. Freeze SHA → integrate map; own tree only.  
9. `sv-mvd` changes → **patch file only**.  
10. Area “done” only after integrate map gate.

---

## 7. Pointers

- Full ALM+DSP+M10K budget: `docs/fit-budget-alm-dsp-m10k.md`  
- Traverse bomb: `docs/cycle-iterative-traverse-area.md`  
- Deblock: **fourth** until traverse+sink maps clear  

**Honest line:** sink is **~1× device ALMs and illegal on DSP** until IQ is serial and planes are memories with FSMs; chroma leaves are not the problem.

---

## Measured dequant DSP baseline (2026-07-30)

Isolated `h264_dequant4x4` map (`dequant-dsp-probe`, `true rc=0`):

- **DSP = 17** (pre-reg 16 — near-HIT): 16× two-indep 18×18 + 1 extra
- **ALMs needed = 240**
- `q/6` and `q%6` → soft `lpm_divide` (**0 DSP**)

**One parallel dequant already exceeds the whole sink ≤12 DSP target.**  
Serial `dequant_one` (16 cycles, one mul) remains mandatory.  
Evidence: `docs/m10k-inference-boundary.md` §Dequant; `.agent-work/integ-wiring/dequant_dsp.map.summary`.

---

## DSP isolation baselines (2026-07-30, integrate)

| Module | Isolated DSP | Isolated ALMs needed | In-tree entity (d57f002) |
|--------|-------------:|---------------------:|--------------------------|
| `h264_dequant4x4` | **17** | 240 | child under sink often **32** (drift) |
| `h264_i16_dc_hadamard` | **3** | 247 | leaf/entity **32** (attribution; not isolation floor) |
| sink whole | — | — | **64 DSP**, 38,687 comb ALUTs |

**Serial dequant is mandatory** (17 > 12). Had is not a 32-DSP floor in isolation.  
Full arithmetic: `docs/fit-arithmetic-post-d57f002.md`.
