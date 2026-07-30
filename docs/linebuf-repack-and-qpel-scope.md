# Line-buffer M10K waste + serial qpel scope (MAP, no FIT)

**No FIT. No RBF. No deploy.** Evidence from existing wire6 post-fit + RTL + product map `4f281e6`.  
Shipping fit SoT: `product-wire6` / RBF `14eaeff3` — `465/553` M10K, **88 free**.

---

## A. Why `ddr_frame` line buffers are 16% efficient

### A.1 Declaration (quoted)

`fpga/Plex_MiSTer/rtl/line_buf_ram.sv`:

```systemverilog
(* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:WIDTH-1];
// true dual-clock: wr_clk vs rd_clk, registered read
```

`fpga/Plex_MiSTer/rtl/ddr_frame_store.sv` (gen + params):

```systemverilog
parameter int LINE_COUNT = 8;           // present_core passes FRAME_LINE_COUNT
localparam int LINE_SLOTS = LINE_COUNT * 2;  // 16 slots (ping-pong sets)
localparam int Y_LINE_QWORDS = CODED_W / 8;
localparam int C_LINE_QWORDS = CODED_W / 16;
// CODED_W from ddr_frame_layout_params.svh: DDR_FRAME_CODED_WIDTH = 624
// → Y_LINE_QWORDS = 78, C_LINE_QWORDS = 39

for (li = 0; li < LINE_SLOTS; li++) begin : gen_line
  line_buf_ram #(.WIDTH(Y_LINE_QWORDS), .AW(...), .DATA_W(64)) yram (...);
  line_buf_ram #(.WIDTH(C_LINE_QWORDS), .AW(...), .DATA_W(64)) uram (...);
  line_buf_ram #(.WIDTH(C_LINE_QWORDS), .AW(...), .DATA_W(64)) vram (...);
end
// → 16×3 = 48 separate arrays
```

### A.2 Fitter RAM Summary (wire6) — exact configs

| Count | Port | Size bits | M10K each | Fits in MLABs |
|------:|------|----------:|----------:|---------------|
| **32** | **39×64** (U+V) | 2,496 | **2** | **No — Block Type Set to Block RAM** |
| **16** | **78×64** (Y) | 4,992 | **2** | **No — Block Type Set to Block RAM** |

48 × 2 = **96 M10K**. Impl bits sum **159,744**.  
Efficiency = 159744 / (96 × 10240) = **16.2%**.  
Ideal bit packing = ceil(159744/10240) = **16** blocks → **6.0× waste**.

### A.3 Root cause (four factors, all measured)

| Factor | Evidence | Role |
|--------|----------|------|
| **1. 48 separate arrays** | `gen_line` × Y/U/V | **Dominant.** Each shallow bank gets its own M10K pair; depth cannot share. |
| **2. DATA_W=64** | instance `.DATA_W(64)`; fitter width 64 | One Cyclone V M10K cannot hold a 64-bit SDP word → **2 blocks wide** per array (Location shows 2 M10K_* sites). |
| **3. Shallow depth** | 39 / 78 vs M10K depth capacity thousands | After paying the 2-wide tax, almost no depth is used → **12–24% bits/block**. |
| **4. Forced Block RAM** | `(* ramstyle = "M10K" *)` → fitter “Block Type Set to Block RAM” | Blocks MLAB packing of tiny memories. Dual-clock (`clk_ddr` wr / `clk` rd) is the **legitimate** reason to want BRAM — but it does not require **48** of them. |

**Not** “inference failed into logic” — these **are** M10K. The bug is **geometry + banking**, not missing `ramstyle`.

### A.4 Read/write concurrency (repack feasibility)

Display path (`ddr_frame_store.sv` comb select):

- Exactly **one** `selected_y_q` / `selected_u_q` / `selected_v_q` per cycle from registered hit index.
- Writes are one-hot `y_wr[li]` / `u_wr` / `v_wr` — one slot filled at a time from DDR burst.

→ **One read port + one write port per plane is enough.** Separate RAMs are not required for multi-port; they are a packing accident of `generate`.

---

## B. Repack scope (do **not** implement on daily driver without a dedicated lane)

### B.1 Proposed shape (design sketch only)

Three dual-clock SDPs (or one per plane):

```
y_mem[ LINE_SLOTS * Y_LINE_QWORDS ]  // addr = {slot, qw}
u_mem[ LINE_SLOTS * C_LINE_QWORDS ]
v_mem[ LINE_SLOTS * C_LINE_QWORDS ]
still DATA_W=64, ramstyle M10K, same wr_clk/rd_clk
```

### B.2 Block return (arithmetic from measured bits + 64-bit geometry)

At 64-bit SDP, each “column pair” holds ~2×10240 bits useful capacity before depth stacks:

| Plane | Bits | LB @ bit pack | Expected @ 64b dual-port (2-wide) |
|-------|-----:|-------------:|----------------------------------:|
| Y | 16×78×64 = 79,872 | 8 | **8** (2-wide × 4 deep) |
| U | 16×39×64 = 39,936 | 4 | **4** |
| V | 39,936 | 4 | **4** |
| **Total** | 159,744 | **16** | **~16** |

| | Blocks |
|--|------:|
| Today (fit) | **96** |
| After banked planes (expected) | **~16** |
| **Returned** | **~80** |
| Chip free today | 88 |
| Free after repack (if fit confirms) | **~168** |

**Pre-register:** return ∈ {72..84} physical M10K; fail claim if fit shows line_buf group > 24.

### B.3 Cost / risk (display path — daily driver)

| Axis | Assessment | Evidence basis |
|------|------------|----------------|
| **ALMs** | Likely **flat or slightly down** (kill 48-way `y_q[]` mux; add slot bits on addr) | wire6 `ddr_frame_store` already **3,486 ALMs / 4,759 comb** — mux tax is real; no map of repack yet → **ALM delta unknown until map** |
| **Cycles (decode)** | **0** — present path, not decoder | |
| **Display latency** | Keep **same** registered read pipeline (rd_addr → rd_data next `clk`) | current `line_buf_ram` already +1 rd_clk |
| **Tearing / underrun** | **Risk if** slot addressing or ping-pong `SECOND_SET_BASE` wrong; refill FSM must still one-hot a single slot | functional risk, not packing math |
| **CDC** | Must remain true dual-clock BRAM; **do not** move to MLAB | dual-clock + `ramstyle` |
| **Timing** | Address MSB steers slot; depth grows — STA unknown without fit | **no fit authorised** |

**Hard rule for this lane:** scope only. Any implementation needs its own review + **map then authorised fit**, never a silent overlay on the live present path.

### B.4 What not to do

- Dropping `ramstyle` to “save blocks” via MLAB on dual-clock line buffers — **unsafe / may not dual-clock**.
- Cutting `LINE_COUNT` to free RAMs — changes underrun behaviour (product/display).
- Claiming ~80 recovered before a **fit** of the repacked RTL.

---

## C. Chroma merge vs blocks (re-answer for `sv-mvd`)

### C.1 Numbers `sv-mvd` may use (labelled)

| Bucket | Physical M10K | Status |
|--------|-------------:|--------|
| Device | 553 | hard |
| Shipping wire6 used | 465 | measured fit |
| Shipping free | **88** | measured |
| Line-buf waste recoverable (expected) | **~80** | **scoped, not fitted** |
| Free if repack lands | **~168** | contingent |
| On-chip RFS 300 MB I420 | ≥90 LB | **still >88 without repack**; with repack ~90 vs ~168 → **tight but possible only after repack + good pack** — policy remains **DDR-backed** preferred (`fit-budget` §4.4) |

### C.2 Decode M10K adds (LB only — map trees, not ship)

| Array | LB blocks | Notes |
|-------|----------:|-------|
| rbsp 8KiB / 16KiB | ≥7 / ≥13 | 1 block/bank risk low (deep×8) |
| plane_y + top_row | ≥2 | small; **1 block each minimum** |
| tc_top 256×6 | ≥1 | efficiency trap if alone |
| chroma plane/top u+v | ≥2–4 | |
| serial MC working RAMs (wire6) | **10** | already **in** shipping (`h264_mc_block` M10K=10) |
| i4_mode | 0 on product-4f DCE | |

### C.3 DSP (unchanged discipline)

`docs/chroma-merge-area-bound.md` scenario A: shared serial IQ → merged product DSP **~55 << 112**.  
Scenario D probe-style **111+8=119 FAIL** — not ship composition.  
**Hold shared-serial-IQ; any new multiplier is a blocker.**

### C.4 ALM wall for merge

| Tree | ALM picture |
|------|-------------|
| Shipping wire6 | **21,021 / 41,910** post-fit; serial MC **519.5 ALMs** |
| Product map 4f281e6 | **375,026** map ALMs — parallel `h264_luma_qpel_block_16x16` **648,918 comb** |
| Probe 788aa5f | 41,666 map incl. probe — **not ship** |

**Chroma cannot merge onto the parallel-MC product map.** It can only target a **wire6-class serial MC** composition.

### C.5 Direct answer

| Question | Answer |
|----------|--------|
| Can chroma fit in **today’s 88** free blocks? | **Unknown / fragile.** Small chroma tops yes (few blocks). **On-chip RFS no** (≥90). Full decode add (rbsp+planes+tc+chroma) ≈ **15–25 LB** plus packing tax — **may fit 88 if no RFS and pack is clean; not proven.** |
| Can chroma fit if line-buf repack returns ~80? | **Plausibly yes on blocks** (~168 free) for neighbor/RBSP/serial-MC class adds **without** on-chip full-frame RFS. **Still not a fit claim.** |
| Number `sv-mvd` should design to | **Block budget: treat free=88 until repack fits; do not assume 168.** Prefer **zero new shallow banks**; share serial IQ; **no parallel dequant**. ALM: assume wire6 shell ~21k + diet sink/trav, **not** 375k parallel MC. |
| 244 ALMs | **Retired** |

---

## D. Serial qpel scope (do **not** build — already exists on ship)

### D.1 Parallel bomb (product map 4f281e6 only)

```
h264_luma_qpel_block_16x16  always @* for oy,ox in 0..15  // 256-way unroll
comb self 648,918 · 0 M10K · under h264_inter_mc_part
```

Fully parallel block filter + window mux — structural, not a tune.

### D.2 Serial engine already in tree + shipping fit

| Item | Quote |
|------|-------|
| RTL | `h264_mc_luma_qpel.sv` — one 6-tap datapath, window in M10K, stream window |
| Cycles (header) | full-pel **259**; fx≠0 fy=0 **444+259**; fx=0 fy≠0 **339+259**; **worst 444+3×339+259 = 1720** |
| Chroma serial | `h264_mc_chroma_epel.sv` — H83+V74+C65; concurrent with luma; join = max |
| Wrapper | `h264_mc_block.sv` — streaming ports (comments document prior **89,888 ALUT** mux bomb) |
| **Wire6 fit** | `h264_mc_block` **519.5 ALMs**, comb 911, **M10K=10**, DSP=0 |
| | `h264_mc_luma_qpel` **349.5 ALMs**, comb 582, M10K=6 |
| | `h264_mc_chroma_epel` **168.4 ALMs**, M10K=4 |

### D.3 ALM save if someone is on the parallel path

| | Parallel (map 4f) | Serial (fit wire6) |
|--|------------------:|-------------------:|
| Luma qpel | **648,918 comb** | **582 comb / 349.5 ALM** |
| MC block total | **674,729 comb / 65 DSP** | **911 comb / 519.5 ALM / 0 DSP** |

**Save ≈ entire parallel bomb (~649k comb → ~0.5k ALM).**  
Product-only 4f281e6 map is a **wiring regression vs shipping serial MC**, not a new invention task.

### D.4 Cycles vs 2,667 @ 240p (scope only)

| Meter | Value | Source |
|-------|------:|--------|
| Budget 320×240@25@20 MHz | **2,666.7 cy/MB** | throughput docs |
| Serial luma worst | **1,720 cy/MB** | `h264_mc_luma_qpel.sv` header |
| Serial luma full-pel | **259** | same |
| Pad if path already 2,474 | **193** | parent / traverse claim — **not re-derived here** |

**Implications (careful):**

1. Worst-case serial qpel **1,720 alone** fits inside **2,667** with **~947** left for parse/IQ/recon/deblock — **tight**, needs real STAGE_CYCLES on P-MBs, not hope.
2. If a path is already **2,474** without counting MC worst-case, **1,720 does not fit in 193 pad** — those meters must be reconciled (I-only vs P, or MC already inside 2,474).
3. Average P-MB is not always worst frac; integer MV is 259 — **design to worst for gate, measure average for UX**.
4. **480p 684 cy/MB remains out of scope** per parent.

**Do not build a second serial qpel.** Integrate/keep `h264_mc_block`; **forbid** `h264_luma_qpel_block_16x16` on product wire.

---

## E. RFS (hold line)

- Product async + init → Error 10106 at full MB_COUNT; class-C async read.
- Map overlay still **0 bits**, **no Info 276029** for `u_recon_store`.
- On-chip RFS ≥90 M10K LB vs 88 free → **block-infeasible on ship without line-buf repack**, and still DDR-preferred.

---

## F. Misses / ownership

| Item | Note |
|------|------|
| ~46% M10K free | Already retired (bits ≠ blocks) |
| “Repack returns 80” | **Expected from arithmetic + geometry; not fitted** — publish as scope |
| Parallel qpel as “the” product wall | True on **4f281e6 product map**; **false on wire6 ship** (serial already) |
| Chroma block PASS | **Not claimed** |

## G. Priority order recommended

1. **Line-buf banked-plane repack** (present path) — largest block unlock; isolated from decode correctness; needs careful display review + map + **later** authorised fit.  
2. **Keep serial MC on any product decode wire** — never reintroduce `h264_luma_qpel_block_16x16`.  
3. **Chroma merge** against 88 free + serial IQ; optional second pass after repack frees ~80.  
4. No new shallow M10K banks without block budget line.

Artifacts: wire6 `Plex.fit.rpt` Fitter RAM Summary + Resource Utilization by Entity; RTL paths above; `docs/m10k-physical-blocks-wire6.md`.
