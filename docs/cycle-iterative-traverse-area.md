# Cycle-iterative area redesign for `h264_p_mb_traverse`

**Audience:** `sv-traverse` (implements). `sv-integrate` (measurements + this review only — does not edit this module).  
**Evidence:** coord-map2d `quartus_map` true rc=0 · ALMs needed **1,241,952** ·  
`h264_p_mb_traverse` **1,180,271 comb ALUTs** (self **1,177,415**) · device **41,910 ALMs**.  
**Honest sentence:** the decoder is functionally exact in simulation and roughly **thirty times too large** to exist on this FPGA.  
**Worked example:** serial `h264_mc_luma_qpel.sv` — **318,897 → ~484 ALMs (~650×)** by killing runtime-indexed fabric arrays and sharing one datapath.

---

## 0. What “cycle-iterative / resource-shared” means here

Not “add a state machine” (traverse already has ~40 states). It means:

1. **At most one expensive array access per cycle**, with the array in **M10K** and a **registered** read data path.  
2. **At most one instance** of each arithmetic/parse datapath (one UE engine, one bit reader, one CAVLC block already — keep it that way).  
3. **No `always @*` / function that indexes a large array with a runtime address.** That is a giant mux tree. Sim loves it; Quartus bills ALMs.  
4. **Latency is cheap; ALMs are not.** Prefer hundreds–thousands of cycles per MB over parallel fabric.

If a construct would instantiate “one mux/ALU per sample or per byte of the buffer,” rewrite it as a counter + one shared unit.

---

## 1. Root cause (quoted structure, not guess)

### 1.1 Runtime-indexed RBSP (primary suspect for the 1.18M self comb)

```systemverilog
// h264_p_mb_traverse.sv — parameter + storage
parameter int MAX_RBSP_BYTES = 8192;
reg [7:0] rbsp [0:MAX_RBSP_BYTES-1];

function automatic bit rbsp_bit_at;
  ...
  rbsp_bit_at = rbsp[byte_i][bit_i];  // runtime index into 8192 bytes
endfunction

task automatic load_res_window;
  ...
  for (k = 0; k < 64; k = k + 1)
    res_win[k] <= rbsp[bbase + k];   // 64 parallel 8192:1 byte muxes in one cycle
endtask
```

This is the **same class of bug** as the old qpel `ref_win [0:440]` port:

| Old qpel (fixed) | Traverse (now) |
|------------------|----------------|
| 441-byte window, runtime `(r,c)` index | 8192-byte RBSP, runtime `byte_i` / `bbase+k` |
| “every index = N:1 mux in fabric” | same |
| 33 mux groups × 441 → ~90k–318k ALMs | 64×8192 byte muxes + bit reads → **~1.18M comb** |

CAVLC child is only **~2,072 comb** in map2d — the bomb is **parent self logic**, consistent with RBSP mux trees + neighbor tables, not the residual parser core.

### 1.2 Other large runtime-indexed / reset-unrolled structures

| Structure | Size | Risk |
|-----------|------|------|
| `i4_mode_top [0:64*4-1]` | 256 × 4b | medium if combo-read |
| `tc_top [0:MAX_MB_W*4-1]` | 256 × 5b | medium |
| `tc_chr_top[2][MAX_MB_W*2]` | similar | medium |
| Reset `for` over full neighbor arrays in one cycle | OK if regs only; **bad** if forces logic RAM |

These will not reach 1.18M alone after RBSP is fixed, but they must go to **M10K + serial clear/update** so they do not become the next cliff.

### 1.3 What is already OK (keep)

- Slice/MB **state machine** (`ST_IDLE`…`ST_RES_MB_END`) — control is fine.  
- **One** `h264_cavlc_residual_block` instance.  
- UE/SE bit engines that advance **one bit or one symbol per cycle** *if* the bit comes from a registered `rbsp_q`, not from `rbsp_bit_at()` mux.  
- Emitting one `res_blk_*` at a time to the sink.

---

## 2. Worked example: what qpel did (copy this pattern)

File: `fpga/Plex_MiSTer/rtl/h264_mc_luma_qpel.sv` (product wire6).

**Rules encoded in the header comments (paraphrase):**

1. Window lives in **RAM**, one sample per cycle — never a flat register array with runtime index.  
2. **Exactly one** 6-tap datapath, time-multiplexed across H and V passes.  
3. Shift-register slide so each new output needs **one** new memory read.  
4. Schedule accepts **hundreds–1700 cycles** per 16×16 block.

**Storage pattern to copy:**

```systemverilog
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] winram [0:511];
reg [7:0] winq;
// read: always @(posedge clk) winq <= winram[rd_addr];
// write: single port, one addr/data per cycle while idle or in a write state
```

**Do not** expose `input [7:0] huge [0:N]` ports into parent modules for random access.

---

## 3. Concrete redesign for traverse

### 3.1 RBSP → single-port M10K bitstream buffer

**Target structure:**

```text
rbsp_mem[0:MAX-1]     M10K bytes
rbsp_wr_ptr           on in_valid && in_ready
bit_pos               current parse bit index (keep 18b if 16KB)
rd_byte_addr          = bit_pos[17:3]  (or window base + offset)
rbsp_q                registered read data (1 cycle latency)
bit_phase             0..7 within rbsp_q
```

**Bit read FSM (replace `rbsp_bit_at`):**

| Cycle | Action |
|-------|--------|
| T0 | present `rd_addr = bit_pos >> 3` to M10K |
| T1 | `rbsp_q` valid; extract `rbsp_q[7 - bit_pos[2:0]]` |
| T2+ | consume bit; `bit_pos <= bit_pos + 1`; if crossing byte, re-address |

UE leading-zero and suffix loops already take multiple cycles — **insert the +1 memory latency into ST_BITS / ST_UE_*** rather than parallel bit peeks.

**Hard rule:** zero combinatorial paths from `rbsp[*]` to next-state logic.

### 3.2 `load_res_window` → 64-cycle serial copy

Today: 64 parallel `rbsp[bbase+k]` in one task call.  
Replace with:

```text
ST_RES_WIN_LOAD:
  k = 0..63
  each cycle: addr = bbase + k;  (after 1-cycle read) res_win[k] <= rbsp_q
  then ST_RES_WAIT / cavlc_start
```

`res_win[0:63]` can stay small **regs** (512 bits) — CAVLC already consumes a 64-byte window.  
Optional: `res_win` also M10K if CAVLC is taught serial fetch; not required for first crash-diet.

### 3.3 Neighbor / nC tables → M10K + serial clear

On slice start, **do not** unroll `for (ti=0; ti<MAX_MB_W*4; ti++)` into one-cycle fabric if it fights RAM inference. Prefer:

- `(* ramstyle = "M10K" *)` for `tc_top`, `i4_mode_top`, chroma tops  
- Clear: counter over ~256 entries, one write/cycle (~256 cycles at IDR — free at 320×240)  
- Read: register address one cycle before use in nC calculation  

### 3.4 Division / modulo for `curr_x/y`

```systemverilog
curr_x = curr_mb % mb_w16;
curr_y = curr_mb / mb_w16;
```

Fine as lpm_divide once per MB, or maintain `mb_x/mb_y` counters on `ST_NEXT_MB` (**preferred**, zero dividers).

### 3.5 What **not** to parallelize

- Do not fetch multiple UE codes in one cycle.  
- Do not instantiate per-4×4 CAVLC.  
- Do not widen RBSP read to “next 32 bits combo.” Use a **shift register bit barrel** filled from `rbsp_q` one byte at a time (8-cycle refill max).

---

## 4. Per-macroblock cycle budget (320×240 @ ~23 fps)

**Real-time envelope (order-of-magnitude):**

| Quantity | Value |
|----------|------|
| Frame | 320×240 = 300 MB |
| fps | 23 → ~13 ms/frame → ~**43 µs/MB** |
| clk (example 50–100 MHz sys) | 50 MHz → **~2160 cycles/MB**; 100 MHz → **~4320 cycles/MB** |

**Suggested budget allocation (50 MHz, ~2000 cy/MB headroom):**

| Phase | Cycles (budget) | Notes |
|-------|-----------------|-------|
| MB header (type, CBP, QP, I4 modes) | 50–200 | multi-cycle UE already |
| Residual window load | **64** | serial RBSP→res_win |
| Per coded 4×4 CAVLC | 20–80 × N blocks | existing engine |
| nC neighbor touch | 1–4 | registered M10K |
| Hand-off `res_blk` beats | N | backpressure OK |
| **Total target** | **≪ 2000** typical I-MB | worst CAVLC-heavy MB still &lt; 4k @ 100 MHz |

If a path needs 10k cycles/MB, **still OK** at 320×240/23 if average stays under budget — measure later. **Do not** buy cycles back with ALMs.

**Existence proof in-tree:** `h264_recon_export` map2d = **210 comb** — same decode path, cycle-iterative DDR push. Qpel worst schedule **~1720 cy/block** and **~484 ALMs**.

---

## 5. ALM targets (pre-register for the *next* map after redesign)

| Module | map2d measured | Target after serial | Gate |
|--------|----------------|---------------------|------|
| `h264_p_mb_traverse` | **1,180,271** comb | **≤ 3,000 ALMs**, DSP ≤ 2 | must |
| `h264_cavlc_residual_block` | 2,072 | ≤ 2,500 (keep) | hold |
| RBSP storage | logic mux | **M10K only** (~64–128 blocks for 8–16KB) | must |
| Neighbor tables | mixed | M10K + few hundred ALMs | must |

**Stretch:** traverse ≤ 1,500 ALMs if bit engine is minimal.  
**Fail:** any map with traverse comb &gt; 10k without a written waiver — stop and re-read §1.

Integrate will run **one** `quartus_map` when traverse publishes a freeze SHA; do not self-launch competing fits.

---

## 6. Implementation checklist for `sv-traverse`

1. Replace `rbsp_bit_at` and all `rbsp[idx]` combo/task mux reads with **addr → wait → rbsp_q**.  
2. Serialise `load_res_window` to 64 cycles.  
3. `(* ramstyle = "M10K, no_rw_check" *)` on RBSP; verified in map log: **no** “uninferred due to asynchronous read”.  
4. Neighbor arrays M10K + serial clear; no 256-iteration combo generate.  
5. MB x/y by counters, not `/` `%` if dividers show up fat.  
6. Keep **one** CAVLC instance; do not touch scorer.  
7. Sim: preserve 300/300 I-luma behaviour **on the same fixtures**; area gate is separate map.  
8. Hand integrate a labelled patch or freeze SHA — **do not** write into other worktrees.  
9. Report: `quartus_map` not required from traverse; integrate owns map. Optional: small unit sim only.

---

## 7. Anti-patterns (will recreate 1.18M)

- `function` reading `rbsp[i]` or `plane[i]` with variable `i`.  
- `for (k=0;k<N;k++) out[k] = big[base+k]` in one clock with N&gt;4 and big in regs.  
- Flattening the entire slice into regs “for sim speed.”  
- `always @*` packing an entire MB of prediction samples.  
- “Temporary” combo path under `ifdef SYNTHESIS` left empty in sim and full in sim-only — product must match the serial form.

---

## 8. Interface stability (so sink/mvd keep working)

Keep the external contract:

- `in_valid/in_byte/in_ready`, `start`, geometry, PPS QP  
- `res_blk_valid` + coeff[0:15] + mb/idx/qp/mode + `res_mb_end`  
- `mb_valid` stream for P headers if still used  

Internal multi-cycle latency before `res_blk_valid` is **allowed** and expected. Downstream already has `res_blk_ready` / `ST_RES_HOLD`.

---

## 9. After traverse is thin

Priority order (parent):  
1. Traverse serial (this doc)  
2. Sink area (see `docs/cycle-iterative-sink-area.md`) — 40k + 64 DSP  
3. Chroma map at `1e1fbe1` (integrate)  
4. Deblock ≤~2.5k (still blocked on budget)

**Fit arithmetic stays unsoftened until traverse map ≤ few k ALMs:**

```
device                         41,910
product                        21,645
traverse (current)          1,180,271   ← must die
sink (current)                 40,439
deblock serial prior           25,433
chroma                         TBD
→ CANNOT FIT (~30×)
```
