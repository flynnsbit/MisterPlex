# Serial-IQ sink interface contract (`cf6842a`)

**Audience:** `sv-mvd` (chroma rebase onto frozen `cf6842a`)  
**Owner:** `sv-traverse` (serial IQ + `res_blk` handshake)  
**Product SHA:** `cf6842a48b8f58b45c7fdebab369f947ac8ea182`  
**Do not edit `rtl/i-slice-luma` until chroma rebase lands.** Patch files both ways.

Correctness at this SHA (clean tree): clip1 `intra_y 300/300` px exact; clip2 `1170/1170` px exact;  
RED `FAULT_SERIAL_IQ_ZERO` → `0/300` (`docs/evidence/cf6842a_sink_serial_iq_correctness.json`).  
Area/DSP: pre-reg ALM 2500..4000, DSP 6..12 — **integrate maps; do not self-launch Quartus.**

---

## 1. Why this document exists

Pre-restructure sink ran **parallel m15+m16 `dequant_one` farms** (~52+ DSP) and **16× Hadamard scale muls** (~32 DSP).  
`cf6842a` replaces that with:

| Module | Role | Mul budget |
|--------|------|------------|
| `h264_dequant4x4_serial` | 4×4 IQ, one mul × ≤16 cycles | **1 DSP lane** |
| `h264_i16_dc_hadamard_serial` | I16 DC Hadamard scale, one mul × 16 cycles | **1 DSP lane** |
| combo `h264_idct4x4` / `h264_recon4x4` | still combo (add/shift) | 0 DSP expected |

**Hard rule for chroma:** do **not** re-introduce a parallel multiplier farm (second dequant instance unrolled, 4- or 16-wide `*` on coeffs, or a private Hadamard mul array). Share the serial engines or add **at most one** additional serial lane with the same start/busy/done discipline. DSP is the buildability wall (112 device; product already tight).

---

## 2. `h264_dequant4x4_serial` — ports and semantics

```systemverilog
module h264_dequant4x4_serial #(
  parameter bit FAULT_FORCE_ZERO = 1'b0
) (
  input  wire        clk,
  input  wire        reset,
  input  wire        start,                 // pulse when !busy
  input  wire signed [15:0] coeff [0:15],   // captured on start
  input  wire [5:0]  qp,                    // QP_Y (already wrap-mod-52 upstream)
  input  wire [4:0]  max_coeff,             // 16 = full; 15 = I16 AC (skip spatial DC)
  output reg         busy,
  output reg         done,                  // 1-cycle pulse; dequant[] stable THIS cycle
  output reg signed [28:0] dequant [0:15]   // zigzag-addressed spatial
);
```

### Timing (NBA-safe)

```
cycle 0:  start=1, busy=0  →  capture coeff/qp/max; busy←1; dequant[]←0; k←0
cycle 1..N: write dequant[zigzag(k)] ← dequant_one(coeff[k], ...); k←k+1
            N = max_coeff (16 or 15). max_coeff==15 ⇒ skip_dc: scans map to zz(k+1), spatial [0] stays 0
cycle N+1:  k>=max ⇒ busy←0, done←1   // last write was prior cycle; sample dequant[] on done
```

- **Do not** sample `dequant[]` on the same cycle as the last write without waiting for `done`.
- `start` while `busy` is ignored (`start && !busy`).
- `FAULT_FORCE_ZERO=1`: on busy, immediately `done` with zeros (RED twin). Sink wires this as `FAULT_SERIAL_IQ_ZERO`.

### Arithmetic contract (bit-exact vs combo / host)

- Same `norm_adjust(q%6, mi)`, `qmul = na*16 << (q/6+2)`, `(c*qmul+32)>>>6` as combo `h264_dequant4x4`.
- **`max_coeff == 15`:** I16 AC path — DC spatial bin stays 0; AC scans use `zigzag(k+1)`.
- **`max_coeff == 16`:** full 4×4 including DC (I4 and chroma 4×4 AC when hooked).

### QP

- Port is **unsigned 6-bit QP already in 0..51 range**.
- **QP_Y wrap (H.264 8.5.1 mod-52)** is done in **`h264_p_mb_traverse`** (`qp_r`), not in the sink.
- Chroma **must** derive QPc from **wrapped** QP_Y (PPS `chroma_qp_index_offset` se(v)). Do not feed pre-wrap signed qp into this engine.

---

## 3. `h264_i16_dc_hadamard_serial` — ports and semantics

```systemverilog
module h264_i16_dc_hadamard_serial (
  input  wire        clk, reset, start,
  input  wire signed [15:0] coeff [0:15],  // I16 DC block (idx 0)
  input  wire [5:0]  qp,
  output reg         busy, done,
  output reg signed [15:0] dc_out [0:15]   // spatial DC after scale
);
```

- Butterflies are **combo add/sub only** (0 DSP); **one** scale mul per cycle for 16 outputs.
- `done` one cycle after last `dc_out[k]` write (same NBA rule as dequant).
- **Luma I16 only** today. Chroma 2×2 DC Hadamard is a **different** transform — do not overload this module with a parallel 16-mul design; keep ≤2 DSP total for any chroma DC scale (serial or tiny combo).

---

## 4. Sink FSM and `res_blk` handshake

File: `fpga/Plex_MiSTer/rtl/h264_i_res_recon_sink.sv`

### Ready / backpressure

```systemverilog
assign res_blk_ready = (st == ST_IDLE) && !write_busy && !pend_mb_end;
```

- Accept **one** `res_blk` beat only in `ST_IDLE` when store is not draining.
- `res_mb_end` may pulse anytime; latched as `pend_mb_end` and served from IDLE after planes stable.
- Downstream `write_busy` must hold off both new blks and MB commit.

### State machine

| State | Action | Exit |
|-------|--------|------|
| `ST_IDLE` | Accept `res_blk_*` → latch `lat_*`; or commit `pend_mb_end` → `write_req` | → `ST_SETTLE` on accept |
| `ST_SETTLE` | **Mandatory 1 cycle** so `lat_coeff` / `lat_qp` are visible to serial engines | → I16_PRED / HAD_WAIT / IQ_WAIT / IDLE |
| `ST_I16_PRED` | Luma I16 DC blk (idx 0): run combo I16 pred into `plane_y` | → `ST_HAD_WAIT` + `had_start` |
| `ST_HAD_WAIT` | Wait `had_done`; paint provisional DC residual on all 16 4×4s; `i16_dc_valid` | → IDLE |
| `ST_IQ_WAIT` | `dq_start` then wait `dq_done` | → `ST_APPLY_PX` |
| `ST_APPLY_PX` | **16 cycles**, one pixel/cycle into `plane_y` (I4 or I16 AC) | → IDLE |

### `ST_SETTLE` dispatch (luma today)

```
if (luma && i16 && idx==0 && !i16_pred_done) → I16_PRED
else if (luma && i16 && idx==0)             → HAD_WAIT (+ had_start)
else if (luma && (i16 AC idx 1..16 || I4 idx 0..15)) → IQ_WAIT (+ dq_start)
else                                         → IDLE   // *** chroma / non-luma currently dropped here ***
```

**Chroma hook point:** extend this branch (and APPLY path) for `!lat_is_luma` — do **not** bypass SETTLE or pulse `dq_start` on the accept cycle.

### Block index conventions (luma)

| `res_blk_is_i16` | `res_blk_idx` | Meaning |
|------------------|---------------|---------|
| 1 | 0 | I16 DC 4×4 (Hadamard path) |
| 1 | 1..16 | I16 AC 4×4 #0..15 (`max_for_iq` forced to 15) |
| 0 | 0..15 | I4 4×4 |

I16 AC: after `dq_done`, APPLY undoes provisional DC paint and adds full IDCT residual when coeffs nonzero (host `idct4x4_add` style). DC inject into `dq_for_idct[0]` is combo mux from `i16_dc[]` — still present.

### Latency note (order of magnitude; clock = **20 MHz** `clk_sys`)

Per accepted luma 4×4 AC/I4 at `cf6842a` (combo plane): SETTLE(1) + IQ(~17) + APPLY(16) ≈ **34 cycles** (+ I16 DC once/MB).  
At `788aa5f` add M10K taxes: MB_INIT 256, HAD_PAINT RMW 768, APPLY I16 RMW 768, MB_DUMP ~788 — see `docs/evidence/throughput_budget_defense_33904df.txt`.  
Oral “~2k cy/MB @ 50 MHz” is **withdrawn**. SoT: 2667@320×240×25 / 684@624×480×25. Prefer serial sharing over parallel DSP.

### What became registered (vs pre-restructure)

| Was | Now |
|-----|-----|
| Combo dequant all 16 lanes same cycle as accept | `lat_*` + SETTLE; serial `dequant[]` valid on `dq_done` |
| Combo Hadamard 16 muls | serial `dc_out[]` on `had_done` |
| Same-cycle plane update from combo IQ | APPLY_PX 16-cycle writeback |
| `res_blk_ready` high almost always when not write_busy | ready only in IDLE (backpressure during IQ/APPLY) |

Traverse / decode_stub must tolerate multi-cycle sink stall (already gated on `res_blk_ready`).

---

## 5. Where chroma must hook (and must not)

### Current behaviour at `cf6842a`

- `res_blk_is_luma=0` → SETTLE falls through to **IDLE without IQ** (chroma deferred).
- `plane_u` / `plane_v` exist and are copied on `write_req`, but stay 128 unless filled.
- Traverse already emits chroma slots (`res_block_i` 16..25 style) with `res_blk_is_luma=0`.

### Required chroma integration shape

1. **Accept path:** same IDLE → latch → SETTLE. No parallel accept of multiple chroma blks without ready.
2. **QPc:** compute from **wrapped QP_Y** + PPS offset; feed serial dequant `qp` port with QPc (0..39 style as host).
3. **Share `u_dq`:** sequence chroma 4×4 through the **same** `h264_dequant4x4_serial` instance (or one sibling serial module, not a 16-wide farm). Wait `dq_done` before IDCT/recon into `plane_u`/`plane_v`.
4. **Chroma DC 2×2 Hadamard:** keep ≤2 DSP; prefer serial or add/shift-only if host allows. **Do not** paste a 16-mul luma Hadamard for chroma DC.
5. **Intra chroma pred:** may stay combo if ALM-cheap; do not multiply residual by parallel Q scale outside the serial IQ.
6. **Neighbours:** luma `top_row` / `left_col` / `tl_for_right_mb` discipline is luma-specific; chroma nb is separate — do not widen luma top_row mux farms without M10K/`h264_byte_ram_sp` pattern.
7. **`write_req`:** still one pulse when `res_mb_end` matches `cur_mb`; U/V must be final before that pulse.

### Explicit non-goals / landmines

| Do not | Why |
|--------|-----|
| Instantiate combo `h264_dequant4x4` beside serial for “chroma only” | Brings back the DSP farm |
| `generate for (i=0;i<16) mul` on chroma coeffs | Same |
| Start serial IQ on the `res_blk` accept cycle without SETTLE | NBA: engines see stale `lat_coeff` |
| Sample `dequant` before `done` | Partial results |
| Assume `res_blk_ready` every cycle | Multi-cycle IQ/APPLY |
| Feed unwrapped / signed QP into `qp[5:0]` | 4× residual class of bug |
| Dual-edit sink while traverse owns serial IQ without patch review | Merge archaeology |

---

## 6. RED / verification expectations for chroma merge

After chroma lands on a tree based on `cf6842a`:

1. Re-score clip1 + clip2 **luma** must remain 300/300 and 1170/1170 (no luma regression).
2. Headline Y+U+V scorer becomes meaningful — publish U/V with SOURCE_SHA.
3. Keep `FAULT_SERIAL_IQ_ZERO` discriminating on luma; add a chroma-specific RED only if it does not weaken the serial-IQ twin.
4. DSP: integrate map of **merged** tree is the only buildability claim. Chroma DC Hadamard ~8 DSP is already a known add — stay inside residual budget under 112.

---

## 7. Patch protocol

- **Base:** freeze `cf6842a` (do not move `rtl/i-slice-luma` until rebase done).
- **sv-mvd:** produce patch / PR against `cf6842a` sink; chroma modules may be new files.
- **sv-traverse:** review patch only — look for parallel muls, missing SETTLE, ready violations, QP wrap bypass. Does **not** edit `sv-mvd` tree.
- **Phase-2 traverse area** (`tc_top` / `i4_mode_top`) lives on branch `rtl/sink-contract-phase2` (or later), mapped **after** merge — not on the freeze branch.

---

## 8. Quick reference: sink instance wiring at `cf6842a`

```text
res_blk_valid/ready ──► ST_IDLE latch lat_*
                            │
                            ▼
                       ST_SETTLE (1 cy)
                      /     |      \
              I16_PRED   HAD_WAIT   IQ_WAIT ── dq_start → u_dq → dq_done
                  \         |              \
                   +-- had_start → u_had    ST_APPLY_PX ×16 → plane_y
                              |
                         plane_y DC paint
                              ▼
                          ST_IDLE
                              │
                     pend_mb_end && !write_busy
                              ▼
                     write_req + write_{y,u,v}
```

Files:

- `fpga/Plex_MiSTer/rtl/h264_dequant4x4_serial.sv`
- `fpga/Plex_MiSTer/rtl/h264_i16_dc_hadamard_serial.sv`
- `fpga/Plex_MiSTer/rtl/h264_i_res_recon_sink.sv`
- Evidence: `docs/evidence/cf6842a_sink_serial_iq_correctness.json`

---

*End contract. Questions → parent; do not silently diverge from start/busy/done + single-mul rule.*

---

## 9. Map result at `cf6842a` (integrate)

| Metric | Pre-reg | Measured | Verdict |
|--------|---------|----------|---------|
| sink DSP | 6..12 | **4** (u_dq=2, u_had=2 shared) | **HIT** |
| whole DSP | — | **111 / 112** | PASS by 1 |
| sink comb | ≤4k ALM gate | **39,155** (self 23,211) | **MISS** — IQ serial removed DSP not fabric |
| i16 pred child | — | **10,643 comb** | phase-2 |
| plane M10K | — | **0 bits** | phase-2 → `h264_byte_ram_sp` |

**Chroma risk is now concrete:** 1 DSP of device headroom. Parallel muls in chroma = instant wall fail.
Phase-2 (serial I16 + plane/top M10K) must not add DSP.

---

## 10. Phase-2 base freeze `788aa5f` — **sv-mvd rebase target**

**Product SHA for chroma rebase:** `788aa5f6` (`plane_y`/`top_row` M10K + serial I16 + serial nb).  
Supersedes freeze `cf6842a` for *new* chroma work. Luma-only correctness at this SHA: clip1 `300/300`, clip2 `1170/1170` (`docs/evidence/p2_plane_m10k_prereg_measure.json`).  
Map @ `788aa5f` (integrate): whole **41,666 ALMs / 111 DSP**; sink comb **8,640** (self 1,927); i16 pred **1,354**; M10K `u_plane_y` 2,048 + `u_top_row` 8,192 bits.

### 10.1 What changed vs §1–§8 (`cf6842a` → `788aa5f`)

| Item | `cf6842a` | `788aa5f` (quoted RTL) |
|------|-----------|-------------------------|
| `plane_y` | `reg [7:0] plane_y [0:255]` | `h264_byte_ram_sp #(.DEPTH(256)) u_plane_y` — **1 we, 1 raddr, registered `q`** |
| `top_row` | fabric regs | `h264_byte_ram_sp #(.DEPTH(MAX_PIC_W)) u_top_row` |
| I16 pred | combo full plane | `h264_intra16x16_pred` stream: `start`/`busy`/`done` + `px_valid` 1 px/cy |
| Neighbours | combo/parallel | `ST_I16_NB` / `ST_I4_NB` with `RD_ISSUE→RD_WAIT→RD_CAPT` (**3 cy/sample**) |
| FSM width | 4-bit, fewer states | `ST_MB_INIT`, `ST_I16_NB`, `ST_I16_START`, `ST_I16_PRED`, `ST_HAD_PAINT`, `ST_MB_DUMP` added |
| `res_blk_*` ports | same | **unchanged** (no new required inputs for luma) |
| Chroma path | SETTLE → IDLE drop | **still** SETTLE else → `ST_IDLE` when `!lat_is_luma` |
| `plane_u`/`plane_v` | regs, stay 128 | **still** `reg [7:0] plane_u/v [0:63]`; dumped on `ST_MB_DUMP` |
| Serial IQ | private `u_dq` | still private `u_dq` in this SHA (no `EXT_SERIAL_DQ` yet) |
| DSP rule | 1 serial DQ + 1 serial HAD | **unchanged** — no second farm |

### 10.2 Ready / accept (unchanged discipline)

```systemverilog
assign res_blk_ready = (st == ST_IDLE) && !write_busy && !pend_mb_end;
```

First blk of a new MB → `ST_MB_INIT` (clear `plane_y` 256×1 we/cy) then `ST_SETTLE`.  
Same-MB subsequent blks → `ST_SETTLE` only.  
`res_mb_end` → latch `pend_mb_end`; from IDLE → `ST_MB_DUMP` (not instant `write_req`).

### 10.3 `ST_SETTLE` dispatch at `788aa5f` (luma only today)

Quoted from `h264_i_res_recon_sink.sv`:

```
if (luma && i16 && idx==0 && !i16_pred_done) → I16_NB or I16_START
else if (luma && i16 && idx==0)             → HAD_WAIT (+ had_start)
else if (luma && i16 && idx 1..16)          → IQ_WAIT (+ dq_start)
else if (luma && !i16 && idx < 16)          → I4_NB or IQ_WAIT
else                                         → IDLE   // chroma / unknown DROPPED
```

**Chroma hook:** extend the final `else` — never skip `ST_SETTLE`, never pulse `dq_start` on the accept cycle.

### 10.4 M10K RMW rule (load-bearing for chroma planes)

Registered single-port pattern (`h264_byte_ram_sp`):

```
cycle 0: raddr <= a;           // RD_ISSUE
cycle 1: wait                  // RD_WAIT  (q not yet for this a)
cycle 2: use q; optional we    // RD_CAPT
```

- **Do not** same-cycle read-modify-write on `u_plane_y` / any new `u_plane_u/v` / `u_top_*`.
- I16 `ST_HAD_PAINT` and I16 AC `ST_APPLY_PX` already pay **3 cy/px** RMW.
- I4 `ST_APPLY_PX` writes **1 cy/px** (pred from combo `i4_pred`, no plane read).
- Chroma 8×8 pred neighbours from `top_u/v` must use the same 3-cy issue/wait/capt if those are M10K.
- Prefer **`h264_byte_ram_sp` module instances** over attributes. Attributes were tried; Quartus declined.

### 10.5 `ST_MB_DUMP` commit contract

After `pend_mb_end`: dump `plane_y` → `write_y[]` (3 cy/px × 256), save TL, write 16 `top_row` bytes, copy `plane_u/v` → `write_u/v`, then **one** `write_req` pulse.  
U/V must be final **before** that pulse. Chroma work that leaves U/V incomplete at dump = silent wrong store (see handoff `mb_written=299` defect).

### 10.6 Q&A — answers blocking `sv-mvd` rebase onto `788aa5f`

| # | Question | Answer (normative) |
|---|----------|-------------------|
| Q1 | Rebase base SHA? | **`788aa5f6`**, not `cf6842a`. Port freeze for luma holds; FSM internals changed. |
| Q2 | May chroma add ports? | **Yes, additive only:** `res_mb_chroma_mode[1:0]`, `chroma_qp_index_offset signed [4:0]`, optional `EXT_SERIAL_DQ` + `ext_dq_*` bundle, optional `nb_commit` for Intra-in-P. Do not rename/remove existing `res_blk_*`. |
| Q3 | Share or duplicate dequant? | **Share one serial engine.** Prefer `EXT_SERIAL_DQ=1` with one `h264_dequant4x4_serial` in `decode_stub` muxed between sink and P-chroma apply. Private second instance = DSP risk (device headroom **1** @ map). |
| Q4 | QP into serial DQ? | Always **wrapped 0..51**. Luma: traverse `qp_r`. Chroma: `QPc = chroma_qp(QP_Y_wrapped, chroma_qp_index_offset)` then feed `qp[5:0]`. Never signed/pre-wrap. |
| Q5 | `max_coeff` for chroma? | Chroma AC 4×4: **16**. Chroma DC 2×2 uses `h264_chroma_dc_hadamard_inv` (≠ luma I16 HAD module). Do not overload `h264_i16_dc_hadamard_serial` for chroma DC. |
| Q6 | Block index map? | Traverse already emits: I: chroma DC/AC after luma; idx conventions in traverse `res_block_i` 16..25. Sink must classify with `!res_blk_is_luma` + idx (see chroma ship `is_chr_dc_slot` / `chr_is_v`). |
| Q7 | `plane_u/v` storage? | At `788aa5f` they are **regs**. Chroma may keep regs (64 B) or move to `h264_byte_ram_sp DEPTH=64`. If M10K: APPLY must 3-cy RMW or write-only after separate pred buffer. **top_u/v must not be wide fabric** — use `h264_byte_ram_sp` (DEPTH=`MAX_PIC_W/2`). |
| Q8 | Can APPLY be 1 cy/px for chroma? | Yes **if** pred sits in regs/combo and residual add does not read M10K same cycle. Matching I4 path. |
| Q9 | `res_blk_ready` during chroma? | Still **only IDLE**. Multi-cycle CHR_NB / IQ / APPLY keeps ready low. Traverse already stalls on `!ready`. |
| Q10 | Parallel 16-mul or combo `h264_dequant4x4` for chroma? | **Forbidden.** |
| Q11 | Latency / budget myth? | Decode clock = **20.000 MHz** (`pll_0002.v` `outclk_0`). SoT budgets: **2667 cy/MB @320×240×25**, **684 @624×480×25** (`docs/decode-throughput.md`). Oral “~2000 @ 50 MHz” is **withdrawn**. Measured IDR `paint_per_mb≈4037` is real wall time (includes I_RECON+DPB+diag paint) — see `docs/evidence/throughput_budget_defense_33904df.txt`. |
| Q12 | Must chroma hold luma scores? | **Non-negotiable:** clip1 Y 300/300, clip2 Y 1170/1170. Also `STORE_MB_BITMAP unique==expected` (no 299). |
| Q13 | Who maps? | `sv-integrate` only. No self-Quartus. Pre-reg ALM before merge. |
| Q14 | Patch protocol | Patch against `788aa5f` (or tip `rtl/sink-contract-phase2` if traverse p2 needed). Traverse lane reviews for parallel muls / SETTLE / ready / QP wrap — does not edit mvd tree. |

### 10.7 Recommended chroma FSM shape (non-binding, proven direction)

Reference implementation (out-of-tree / other worktree): `rtl-chroma-intra-ship` on `788aa5f` with `EXT_SERIAL_DQ`, M10K `plane_u/v`+`top_u/v`, states `ST_CHR_NB/START/WAIT/PAINT/DC_ONLY`. Normative constraints are §10.1–10.6; that tree is evidence of a workable shape, not a second SoT.

```
IDLE → (new MB) MB_INIT → SETTLE → {luma path | CHR_NB → CHR_PRED → IQ_WAIT → APPLY_CHR}
     → … → MB_DUMP → write_req
```

### 10.8 Explicit non-goals still in force

| Do not | Why |
|--------|-----|
| Re-parallelise serial IQ / serial I16 pred | Undoes ALM/DSP wins (i16 10k→1.3k comb) |
| Attribute-annotate arrays for M10K | Quartus silently declined; use `h264_byte_ram_sp` |
| Sample `dequant[]` before `done` | Partial results |
| Start DQ on accept cycle | NBA: stale `lat_coeff` |
| Feed unwrapped QP | 4× residual class bugs |
| Dual-edit freeze while both lanes write sink | Merge archaeology |

*End §10. Owner: sv-traverse. Questions that change §10 → parent ticket, not silent drift.*
