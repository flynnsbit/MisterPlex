# Decoder clock domain (≠ Route A) — evidence verdict

**Lane:** w-clock · **No fit · No device · No PLL edit applied**  
**Pre-register:** `.agent-work/w-clock/DECODE_CLK_DOMAIN_PREREG.md`  
**Related prior (same conclusion, re-verified):** `.agent-work/w-fit-1/CLK_DECODE_DESIGN.md`, `JOB1_CRITICAL_PATHS_8fdf440f.md`

---

## Parent throughput wall (re-derived, true rc=0)

```
GEOMETRY     fps   MBs    MB/s   cy/MB@20   cy/MB@50
624×480       24   1170   28080     712.3     1780.6
624×480       30   1170   35100     569.8     1424.5
320×240       24    300    7200    2777.8     6944.4
1280×720      30   3600  108000     185.2      463.0
```

vs serial CAVLC ~**2200 cy/MB**:

| Case | Budget | Need | Ratio short |
|------|-------:|-----:|------------:|
| 624@24 @20 MHz | 712 | 2200 | **3.09×** |
| 624@24 @50 MHz | 1781 | 2200 | **1.24×** |
| 320@24 @20 MHz | 2778 | 2200 | OK if ≤2200 holds |

**Even a perfect 50 MHz decode domain does not close the dominant library class** without a cy/MB diet and/or parallelism. 50 MHz only reduces the gap.

---

## 1. What clock does decode sit on today?

**Answer: `clk_sys` = 20.000 MHz. Confirmed.**

| Quote | File |
|-------|------|
| `.output_clock_frequency0("20.000000 MHz")` | `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` |
| `.outclk_0(clk_sys)` | `Plex.sv` PLL instance |
| `stream_path … .clk(clk_sys)` | `Plex.sv` ~640 |
| `module stream_path ( input wire clk, …)` → all NAL/stub/bitstream on `clk` | `stream_path.sv:9` |
| `decode_stub … .clk(clk)` | `stream_path.sv` under `` `ifndef PRODUCT_NO_STUB `` |
| `h264_decode_top ( input wire clk, …)` — **single clock port** | `h264_decode_top.sv:21` |

**P1 HIT.**

There is **no** `clk_decode` net in the product tree.

---

## 2. PLL outputs and spare headroom

**SoT:** `pll_0002.v` (not stale `pll.v` megawizard strings).

| outclk | Default freq | Role |
|--------|-------------:|------|
| 0 | **20.000 MHz** | `clk_sys` — beam, present, **entire stream_path/decode** |
| 1 | 50–142 MHz (macro) | `clk_sdram` — **not** decode |
| 2 | **90.000 MHz** | `clk_ddr` / `DDRAM_CLK` — frame store + f2sdram |
| 3 | 0 MHz default; optional **29.7 / 37.125** if `PRESENT_CLK_PIX_PLL` | `clk_pix` (Route B product keeps pix=`clk_sys`) |
| 4…17 | **0 MHz** | **Unused C-counters in the altera_pll parameter block** |

Default `number_of_clocks(3)`; with `PRESENT_CLK_PIX_PLL` → 4.

**Spare:** counter **4+ at 0 MHz** can host a proposed `clk_dec` (e.g. 50.0 MHz from 50 MHz ref / VCO 360 as today) **without touching beam 20 or ddr 90**.  
**Not free:** raises `number_of_clocks`, SDC exclusive-group membership, and all new CDCs (below). **Not applied** — proposal only.

**P2 HIT** (no dedicated decode clk). **P3 HIT** (spare counter exists on paper).

VCO today: STA clock network shows fractional PLL **360.0 MHz** with divclk 20 and 90 — headroom to emit 50 MHz is **PLL-parameter-plausible**; **closure is STA of the *logic* on that domain**, not the counter math.

---

## 3. Realistic Fmax of the decode datapath

### 3.1 Measured whole-chip `clk_sys` Fmax (quoted STA)

| Artifact | RBF / cargo | clk_sys Fmax | Source |
|----------|-------------|-------------:|--------|
| deploy2 / t7b class | stub-in `8fdf440f` | **23.46 MHz** | `remote_out/deploy2/Plex.sta.rpt` Fmax Summary; JOB1 |
| product-wire6 | stub-in class | **23.16 MHz** | same tree STA |
| slot11 | | **25.09 MHz** | wt-clock `remote_out/slot11` |
| fit-nostub-chrome | `PRODUCT_NO_STUB` `c74c6863` | **32.59 MHz** | `post_fit_timing_nostub.log` |

### 3.2 What sets stub-in Fmax 23.46 (quoted JOB1)

```
From: stream_path|decode_stub|lat_p_mb_addr[5]
To:   stream_path|decode_stub|mv_col_al_x[7]
Data Delay: 42.333 ns
Relationship: 50.000 ns  → Fmax = 1000/(50−7.370) = 23.46 MHz
```

RTL cone: `%` / `/` on MB address in `decode_stub` (JOB1 + CLK_DECODE_DESIGN).  
**⇒ Fmax is limited by dark stub MV logic, not by the beam.**

### 3.3 Does stub Fmax “transfer” to `h264_decode_top`?

| Fact | Evidence |
|------|----------|
| `h264_decode_top.sv` exists and is bit-exact in **sim** (parent) | parent claim; not re-run here |
| **Not in `files.qip`** | `files.qip` has `h264_decode_core.sv`, **not** `h264_decode_top.sv` |
| **Not instantiated** in `stream_path` / `Plex.sv` | only `decode_stub` under `` `ifndef PRODUCT_NO_STUB `` |
| Product under `DDR_FRAME_STORE` | `fs_wr_*` **unconnected**; pixels = ARM → HPS DDR → `ddr_frame_store` |

**Fmax of `h264_decode_top` on silicon: UNKNOWN — no fitted STA of that module.**  
Saying “50 MHz will close” for it is a **rule-0 violation**.

**P4 MISS detail:** pre-registered “40–55 MHz if decode not on critical path.”  
- For **current fitted stub cone**: path delay **42.3 ns ⇒ ~23.5 MHz ceiling** until pipelined — **50 MHz is a hard fail if that cone moves as-is**.  
- For **nostub empty-of-stub sys**: **32.59 MHz measured** — still **not** a decode Fmax.  
- For **future real decode island**: **unknown** until a parent-granted fit with the island on its own clock.

### 3.4 Domain rename does not shrink comb delay

Constraining the **same** 42.3 ns path to a 20 ns (50 MHz) period **fails STA** regardless of wire name `clk_decode`.  
**Pipeline / kill `%`/`/` first; raise clock second.** (Prior CLK_DECODE_DESIGN — reaffirmed.)

---

## 4. CDC: decoder → frame store

### 4.1 Product reality (must not fantasize a free path)

Under `DDR_FRAME_STORE=1` (shipping):

```systemverilog
// present_core.sv
`ifdef DDR_FRAME_STORE
  assign fs_wr_ready = 1'b1;
  ddr_frame_store #(...) fstore ( /* rd_*, doorbell, DDRAM_* — no wr_en */ );
`else
  frame_store #(...) fstore ( .wr_en(fs_wr_en), ... );
`endif
```

**Fabric decode `fs_wr_*` does not reach the product frame store.**  
Product path: **ARM decode → doorbell → `ddr_frame_store` on `clk`+`clk_ddr`**.

So “decoder and beam are decoupled by the DDR frame store” is **true for ARM→store→beam**, and **false today for fabric_decode→store** (no write port).

### 4.2 Existing multi-clock in store (w-mem owns; do not edit)

From `ddr_frame_store.sv` + `docs/cdc-crossing-inventory.md`:

| Crossing | Mechanism |
|----------|-----------|
| `clk_sys` ↔ `clk_ddr` | Related PLL edges (same PLL, 0 ps shift); STA relationship **5.555 ns** @ 20/90 |
| Line want_y | **Gray** 2FF |
| Input cmds | **`async_fifo`** wr=`clk` rd=`clk_ddr` |
| Scanout linebufs | DDR-side BRAM → sys-side `_v1` (structural CDC; sets sys setup slack family) |

Tightest **design** setup on stub-in (JOB1):  
`ddr_bitstream_reader` (clk_sys) → f2sdram (clk_ddr) **+0.333 ns** — related half-cycle, **not** deep ALU.

### 4.3 If `clk_dec` @ ~50 MHz is introduced

| Crossing | Required protection | Owner |
|----------|---------------------|--------|
| Host/ioctl / SPI config → decode | async FIFO or stable+toggle (existing bitstream FIFO style) | w-clock / stream |
| Bitstream bytes → decode | already FIFO in stream_path; re-clock wr or rd side | stream |
| Decode recon pixels → **new** store write port | **async_fifo or dual-clock BRAM + commit** into `clk` or `clk_ddr` | **w-mem** must add write path; w-clock must not edit store |
| Decode ↔ DPB DDR | likely via arbiter on `clk_ddr` — more related/async edges | w-mem + decode |
| Status/stats back to clk_sys | Gray or FIFO | either |

**Existing store CDC does *not* automatically cover a third domain.**  
Related-clock inclusion of 50 with 20/90 **tightens edge families**; false-pathing whole interfaces is **forbidden** (gate self-weakening).

**P5 PARTIAL MISS:** store has sys↔ddr CDC, but **not** a fabric decode write seam.

---

## 5. Verdict (honest)

| Question | Answer |
|----------|--------|
| Is separate decode PLL **conceptually** valid (≠ Route A)? | **YES** — beam stays 20; glass stays Route B ascal. |
| Is it a **free win** to 50 MHz? | **NO.** |
| Does 50 MHz alone close 624×480@24 @ ~2200 cy/MB? | **NO — still 1.24× short.** |
| Can we claim decode Fmax ≥50 today? | **NO — unknown for real top; stub cone ≤~23.5.** |
| Binding order of work | **(1)** fabric write into `ddr_frame_store` (w-mem) if fabric DP is the goal · **(2)** cy/MB diet + pipeline hot paths · **(3)** then `clk_dec` PLL + CDC + **parent fit STA** |
| Dead end? | **50 MHz-only as the plan = dead end for dominant class.** Separate domain remains a **useful tool after path cuts**, not instead of them. |

### Pre-register scorecard

| ID | Result |
|----|--------|
| P1 decode on clk_sys 20 | **HIT** |
| P2 no dedicated decode clk | **HIT** |
| P3 spare PLL counter | **HIT** (out4+ @ 0 MHz) |
| P4 Fmax 40–55 achievable | **MISS as stated** — stub cone ~23.5; real top **unknown**; nostub 32.59 is empty-of-stub |
| P5 store already covers decode→store CDC | **MISS** — no fabric wr; sys↔ddr only |
| P6 CDC cost real | **HIT** |
| P7 50 MHz still short 1.24× | **HIT** |

---

## 6. Staged proposal (not applied)

**Stage 0 — evidence only (this commit):** wall JSON + gate; no RTL clock change.

**Stage 1 — path cut (decode owners):** replace comb `%`/`/` MB walk; measure cy/MB on Verilator (`scripts/run_verilator.sh`) toward ≤1780 (50 MHz class) or ≤712 (20 MHz class).

**Stage 2 — w-mem:** product `ddr_frame_store` **write** port + doorbell coupling for fabric recon (or explicit hybrid keep ARM).

**Stage 3 — PLL (parent fit grant):** e.g. `output_clock_frequency4("50.000000 MHz")`, `number_of_clocks` bump, wire `clk_dec` → `stream_path` only; **beam stays outclk_0 @20**.

**Stage 4 — STA gates:** `make post-fit-timing` must show **clk_dec Fmax ≥ target** with **quoted** report; related-edge CDC slack ≥0; beat-conservation TB on decode→store FIFO.

**Exact PLL string (proposal only):**

```
.output_clock_frequency4("50.000000 MHz"),  // clk_dec — NOT applied
```

Do **not** raise `clk_sys` (that re-opens Route A / beam / ascal coupling).

---

## 7. What this is not

- Not Route A (native 720p beam @30.24). Route A remains **killed** (stub Fmax 23.46 < 30.24).  
- Not a claim that fabric decode is product-live under `DDR_FRAME_STORE`.  
- Not an applied PLL bump.
