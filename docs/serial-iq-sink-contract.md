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

### Latency budget (order of magnitude, 50 MHz)

Per accepted luma 4×4 AC/I4: SETTLE(1) + IQ(~17) + APPLY(16) ≈ **34 cycles** (+ I16 DC pred/had once per MB).  
Generous vs ~2k cy/MB budget. Prefer serial sharing over parallel DSP.

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
