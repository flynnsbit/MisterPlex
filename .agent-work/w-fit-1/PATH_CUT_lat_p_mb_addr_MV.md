# Path cut analysis — `lat_p_mb_addr → mv_col_al_x` (no fit)

**Reports:** `fit-t7b-prog480` / RBF `8fdf440f` · STA dump  
`.agent-work/w-fit-1/clk_sys_intra_setup.txt` (quartus_sta, no fitter)  
**RTL:** `fpga/Plex_MiSTer/rtl/decode_stub.sv`

---

## 0) Answer first — is this product logic?

| Config | `decode_stub` in netlist? | Paints product pixels? | Owns clk_sys Fmax 23.46? |
|--------|---------------------------|------------------------|---------------------------|
| **t7b `8fdf440f`** (`DDR_FRAME_STORE=1`, no `PRODUCT_NO_STUB`) | **YES** — hierarchy ALM **9216.9**, M10K **268** | **NO** — `present_core` DDR branch does not wire `fs_wr_*` into `ddr_frame_store` (dark silicon; gate `test_product_no_stub_dark_silicon.sh`) | **YES** — path is inside stub |
| **`c74c6863`** (`PRODUCT_NO_STUB=1`) | **NO** — 0 entity rows | N/A | **NO** — Fmax sys **32.59 MHz** |
| Research / STREAM (macro off) | YES | Only if legacy SPI present path | YES if fitted |

**Conclusion (the problem can disappear for product):**

1. **Shipping with `PRODUCT_NO_STUB` (already proven on c74c6863):** this entire Fmax limiter is **gone**. Product clk_sys Fmax is **32.59 MHz ≥ 25**. No path cut required for a 25 MHz product sys clock *from this path*.
2. **t7b/8fdf still fitted ~9k ALM of dark stub** and paid Fmax 23.46 for logic that cannot paint. That is a **fit tax**, not a pixel path.
3. **Fabric-decode research** that keeps `decode_stub` in the netlist **does** need this cut (or equivalent) before a 25 MHz cy/MB budget is STA-real.

Parent working core `c5382bee` baseline ALM ~21k is **not** the nostub 14.3k class — treat stub presence as **unknown without that RBF’s hierarchy**; do not assume. For **any** build that still maps `decode_stub`, the analysis below applies.

---

## 1) Path characterisation (quoted STA)

```
From: decode_stub|lat_p_mb_addr[5]
To:   decode_stub|mv_col_al_x[7]
Data Delay:             42.333 ns
Number of Logic Levels: 28
Data path Cell delay:   27.635 ns  (65%)
Data path IC (route):   14.698 ns  (35%)
Setup relationship:     50.000 ns  (20 MHz)
Slack @20 MHz:          7.370 ns
⇒ Fmax = 1000/(50−7.370) = 23.46 MHz
```

### Logic vs routing

| Share | ns | % | Implication |
|------:|---:|--:|-------------|
| **Cell (logic)** | **27.6** | **65%** | **Dominated by logic** — pipelining / algorithm change **can** buy multi-ns |
| IC (routing) | 14.7 | 35% | Not routing-only; a pure place-seed hope is weak |

### Structure (data arrival elements)

1. **`Add8`** — carry chain on `lat_p_mb_addr + 1` (`lat_p_next_mb_addr`).
2. **`Mod2|auto_generated|divider|…`** — long **combinational integer divider** (lpm_divide style): many `add_sub_*`, `selnose[*]`, `op_*` stages. This is the bulk of the 28 levels / ~42 ns.
3. Index into `mv_above_x[lat_p_next_mb_x]` → `mv_col_al_x`.

**RTL source of the divider** (`decode_stub.sv:525-528`):

```systemverilog
wire [15:0] lat_p_next_mb_addr = lat_p_mb_addr + 16'd1;
wire [15:0] lat_p_next_mb_x16 = (lat_p_mb_width == 16'd0) ? 16'd0
                              : (lat_p_next_mb_addr % lat_p_mb_width);  // ← Mod2
wire [15:0] lat_p_next_mb_y16 = … (lat_p_next_mb_addr / lat_p_mb_width);
// then same cycle:
mv_col_al_x <= mv_above_x[lat_p_next_mb_x[…]];
```

Same pattern at `:520` for `first_mb_addr % p_mb_width` and DPB `%` at `:489`.

**Not a mystery netlist blob — it is comb `%` / `/` on the MB raster.**

### 25 MHz without a cut (arithmetic, no fit)

Period @25 MHz = **40.000 ns**. Path = **42.333 ns** → slack ≈ **−2.3 ns** → **FAIL**.  
Agrees with Fmax 23.46 &lt; 25. **No STA re-time needed to refuse a blind PLL bump on a stub-in build.**

---

## 2) Minimal cut (proposal — not implemented this turn)

### Preferred: **incremental MB x/y counters** (remove comb `%`/`/` on the advance path)

On `p_fetch_advance`, instead of:

```text
addr' = addr+1;  x' = addr' % mb_w;  y' = addr' / mb_w;  mv_col = above[x']
```

do:

```text
if (lat_p_mb_x + 1 >= lat_mb_w) begin
  lat_p_mb_x <= 0;
  lat_p_mb_y <= lat_p_mb_y + 1;
end else
  lat_p_mb_x <= lat_p_mb_x + 1;
lat_p_mb_addr <= lat_p_mb_addr + 1;
// mv_col_al_* from lat_p_mb_x'/y' (next), still one add + compare + mux — few levels
```

Seed x/y once from `first_mb_addr` using **registered** div (multi-cycle at slice start) or the existing pending path (`pending_p_mb_x` already used at `:1029`).

| Item | Pre-reg |
|------|---------|
| ns saved on this path | **~25–35 ns** (remove divider; leave add+mux ~few ns) — **HIT if Fmax jumps well past 25** |
| ALM | **−hundreds** (delete `lpm_divide` Mod2 and likely Div companion), not +pipeline ALMs |
| Registers | **+0…+16** if slice-start div is registered once |
| Bit-exact | **Must** keep 300/300 and 1170/1170; advance order identical to `%`/`/` raster |
| DSP | 0 expected |

### Fallback: pipeline register after `%`/`/`

One FF on `lat_p_next_mb_x/y` before `mv_col_*` use — saves timing but **adds a cycle of MV neighbour latency** → behaviour change risk; worse than counter fix.

### What this does **not** fix

- Other comb divs (`first_mb_addr %`, `dpb_fill_mb_addr %`) may become the **new** Fmax limiter after Mod2 dies — expect a new path in the same family; pre-reg **second** cut if Fmax lands 25–28 only.

---

## 3) STA “Fmax ≥ 25 with decode present”

| Build | Decode in netlist? | clk_sys Fmax | ≥25? |
|-------|-------------------|-------------:|:----:|
| t7b `8fdf440f` (current path) | yes | **23.46** | **NO** |
| After counter cut | yes | **unknown — needs fit** | goal |
| c74c `PRODUCT_NO_STUB` | **no** | **32.59** | **YES** (decode absent) |

**Cannot claim post-cut Fmax without a parent-granted fit** (or at least map+sta of a stub-in build).  
**Can claim:** product nostub already clears 25 MHz **intra-sys** Fmax without this cut.

No Quartus fit requested this turn.

---

## 4) DDR / freeze interaction if clk_sys → 25 MHz alone

| Topic | Evidence / status |
|-------|-------------------|
| Binding slack today | clk_ddr setup **+0.333** on **sys→ddr** half-cycle, relationship **5.555 ns** (`ddr_bitstream_reader`→`f2sdram`) |
| Raise **clk_ddr** | **Forbidden as free win** — tightens 5.555 ns relationship |
| Raise **clk_sys only** 20→25 | PLL counters change; **related-edge table is not guaranteed** to stay 5.555 ns. Slack **may improve or worsen** — **unknown without STA of a 25 MHz PLL config** |
| Freeze class | `ddr_frame_store` bank-swap / fill FSM sits on **clk_ddr + clk_sys CDC**. Any PLL change must re-run `test_ddr_frame_store_scanout_freeze.sh` (execute, not skip; PINNOTFOUND=rc=2) + shear discrimination |
| False path policy | Do **not** widen cuts to close 25 MHz. Existing narrow `*async_fifo*mem*→*rd_data_r*` only |

**Pre-reg if a 25 MHz sys fit is ever granted (stub-in or nostub):**

| Metric | Baseline (use **named RBF**) | Predict |
|--------|------------------------------|---------|
| clk_sys constrained | 20 → **25** MHz | |
| clk_sys Fmax (nostub c74c class) | 32.59 | still ≥28 |
| clk_sys Fmax (stub-in after counter cut) | 23.46 | **≥28** (miss if new div path) |
| clk_ddr setup | +0.333 (t7b) / +0.559 (c74c) | **≥ +0.25** or HARD_FAIL |
| Freeze / shear / bit-exact | green | must stay |

---

## 5) Recommendation (priority order)

1. **Product / daily-driver path to 25 MHz sys (if ever desired):** ship **`PRODUCT_NO_STUB`** (already Fmax 32.59). **No MV path cut required** for this limiter. Still need full STA on a real 25 MHz PLL + freeze gates — not a silent `pll_0002` edit mid-flight.
2. **Fabric-decode research still linking `decode_stub`:** implement **incremental x/y counters**, kill comb `%`/`/` on the advance path; unit bit-exact; then request fit for Fmax proof.
3. **Do not** burn a slot only to “cut 3 ns” if the stub is not in the shipping netlist — **elision of dark stub already removed the limiter** on c74c6863.

---

## Pre-reg hits/misses this note

| Claim | Result |
|-------|--------|
| Path is routing-dominated | **MISS** — 65% cell / 35% IC; logic cut is appropriate |
| Path is product pixel path | **MISS** — dark under DDR; removed by PRODUCT_NO_STUB |
| Blind 25 MHz works with stub-in | **MISS** — 42.3 ns > 40 ns |
| c74c Fmax supports 25 MHz without stub | **HIT** — 32.59 ≥ 25 (intra); CDC still unchecked at 25 |
