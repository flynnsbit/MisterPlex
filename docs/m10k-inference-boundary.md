# M10K inference boundary (measured)

**Owner:** sv-integrate (measurement gate).  
**Audience:** `sv-traverse` (RBSP/neighbour redesign), `sv-mvd` (any new arrays).  
**Tool:** `quartus_map` only · device **5CSEBA6U23I7** · image `ghcr.io/raetro/quartus:mister` · **no fit**.  
**Build tree:** `/home/flynnsbit/mplex-builds/m10k-infer-probe/` · logs `.agent-work/integ-wiring/m10k_*`  
**Pre-register:** `.agent-work/integ-wiring/m10k-infer-preregister.txt` (written **before** maps).

## Programme question

Will a restructured RBSP (bounded ports, one access/cycle, registered address) actually
infer M10K — or will Quartus decline again the way it did for `ramstyle` on the
multi-port dynamic `rbsp`?

**Answer: YES for the textbook pattern. The cycle-iterative plan assumption HOLDS.**

Falsifier was: textbook map with `block memory bits = 0`. Measured textbook bits = **65,536**.

---

## Pre-register vs measured

| Variant | Pattern | Pre-reg M10K? | Pre-reg bits / ALMs | Measured bits | Measured ALMs needed | Measured M10K? | Score |
|---------|---------|---------------|---------------------|---------------|----------------------|----------------|-------|
| **A textbook** | 8192×8, 1R1W, **registered addr**, 1 access/cy, `ramstyle=M10K,no_rw_check` | YES | 65536 / ≤80 | **65,536** | **29** | **YES** (Simple Dual Port, 8 RAM segments) | **HIT** (blocks 8 vs pred 7 — minor) |
| **B dualrd** | 2 independent registered reads + 1 write | YES shared | 65536 / ≤120 | **131,072** (2×) | **55** | **YES but REPLICATED** two SDP M10Ks | **PARTIAL MISS** — not one true-dual copy |
| **C combo** | async/`assign rd = mem[addr]` | NO | 0 / high | **0** | **45,229** | **NO** — Info **276007** asynchronous read | **HIT** |
| **D wide64** | 64 parallel `mem[base+k]` in one cycle (traverse `load_res_window`) | NO | 0 / 100k–1M | **0** | **45,982** | **NO** — 65,568 regs (array as flops) | **HIT** no-M10K; ALM pred high-side **MISS** (46k not 1M; still > device) |

All four maps: `true rc=0`.

### Quoted evidence

- A: `RAM_BLOCK_TYPE = M10K`, summary `Total block memory bits : 65,536`, rpt ALMs needed **29**, entity `Simple Dual Port 8192×8`.
- B: two rows `mem_rtl_0` and `mem_rtl_1` each M10K SDP 65536 → **replication**, not single true-dual packing.
- C: `Info (276007): RAM logic "m10k_rbsp_combo:u|mem" is uninferred due to asynchronous read logic`.
- D: `Total block memory bits : 0`, `Total registers : 65568`, ALMs needed **45982**. No M10K. (Standalone bomb is smaller than full traverse 1.18M ALUTs because surrounding parse/state is absent — still **over the 41,910 device alone**.)

---

## The rule (design against this edge)

```
INFER M10K when ALL of:
  1. Memory read data is registered (clocked read; no assign mem[addr])
  2. Address presented to the array is a registered/stable port pattern
     Quartus can see as ≤1 read port (and ≤1 write) per inferred block
  3. At most one read index and one write index per cycle per copy
  4. No N-wide "for (k…) q[k] <= mem[base+k]" in one cycle

DO NOT INFER when ANY of:
  - Combinational/async read  → 276007, full fabric (A/C boundary)
  - N≥2 parallel dynamic indexes in one cycle without separate inferred copies
    → register array + mux tree (D; traverse bomb class)
  - ramstyle alone with illegal access  → still uninferred (coord-map2b lesson)

DUAL READ:
  Two registered read ports → tool may REPLICATE the whole M10K (2× bits).
  Budget 2× depth×width bits if you need 2 reads/cycle, OR time-mux one port
  (1 read/cycle) to keep a single copy. Prefer time-mux for RBSP.
```

### What `sv-traverse` should implement for RBSP

Copy **variant A** exactly (same shape as `h264_mc_luma_qpel` `winram`):

```systemverilog
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] rbsp [0:8191];
reg [12:0] rd_addr_q;
reg [7:0]  rbsp_q;
always @(posedge clk) begin
  if (wr_en) rbsp[wr_addr] <= wr_data;
  rd_addr_q <= rd_addr;          // registered address
  rbsp_q    <= rbsp[rd_addr_q];  // one read / cycle
end
// load_res_window: 64 cycles, one byte per cycle into res_win[k]
```

**Do not** ship dual-read RBSP unless M10K budget explicitly pays 2× (131072 bits).  
**Do not** use async `rbsp_bit_at()` into the array — bit extract from `rbsp_q` only.

---

## Dequant DSP baseline (same session)

**Pre-register:** `.agent-work/integ-wiring/dequant-dsp-preregister.txt`  
**Map:** `true rc=0` · log `dequant_dsp_map.log`

| Item | Pre-reg | Measured |
|------|---------|----------|
| Module | `h264_dequant4x4` alone | same |
| DSP | **16** | **17** (16× “Two Independent 18×18” + 1× “18×18 plus 36”) |
| ALMs needed | 400–2500 | **240** |
| Block mem | 0 | 0 |
| Div/Mod `q/6`,`q%6` | soft | **0 DSP** (lpm_divide soft) |

**Score:** DSP **near-HIT** (17 vs 16). Parallel farm is **~17 DSP per dequant4x4 instance**.

### Implication for sink ≤12 DSP

- One parallel `h264_dequant4x4` already **17 > 12**.  
- map2d/map3 sink **64–92 DSP** = multiple IQ/had paths on top of product **74**.  
- Serial IQ (one `dequant_one` lane, 16 cycles) is **mandatory**, not optional: target **0–2 DSP** for dequant as in `docs/cycle-iterative-sink-area.md`.  
- Hadamard parallel **~32 DSP** (prior map) must also serialise or share.

---

## Honest one-liner

*Textbook single-port registered RBSP **does** infer M10K (65,536 bits, 29 ALMs).  
Async read and 64-wide dynamic windows **do not** (0 bits, ~46k ALMs).  
Dual registered reads infer M10K but **replicate** (2× bits).  
Parallel `h264_dequant4x4` alone is **17 DSP** — over the entire sink DSP budget before anything else.*

