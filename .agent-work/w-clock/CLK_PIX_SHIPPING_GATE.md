# clk_pix — shipping product gate (w-clock)

**Status:** design + RTL scaffold **landed**; PLL **not applied**; macros **default OFF**.  
**Why load-bearing:** parent product path is PMS 960×540 → ARM 34.50 ms (+7.16) → fabric 1280×720 glass. Without `clk_pix` @ **29.7 MHz**, CEA 1650×750 scan-out is capped at **20 Mpix/s ≈ 16.16 Hz**. The measured ARM path is academic until this lands.

No device. No fit by this lane. Negative STA slack = hard fail (parent).

---

## 1) Concrete PLL output (item 1)

### Shipping today (`pll_0002.v` SoT — do not cite stale `pll.v` strings)

| Out | String | Net |
|----:|--------|-----|
| 0 | `"20.000000 MHz"` | `clk_sys` |
| 1 | SDRAM macro (default 100) | `clk_sdram` |
| 2 | `"90.000000 MHz"` | `clk_ddr` |
| 3 | `"0 MHz"` / unused | — |
| `number_of_clocks` | **3** | |

### PIX24 — first justified apply (720p24 CEA)

```verilog
// PROPOSED — parent fit grant required before paste into pll_0002.v
.fractional_vco_multiplier("true"),   // was false; exact 29.7 (HDMI pll already does 148.5 frac)
.reference_clock_frequency("50.0 MHz"),
.number_of_clocks(4),                 // was 3
.output_clock_frequency0("20.000000 MHz"),  // clk_sys UNCHANGED — not a sys bump
.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),
.output_clock_frequency2("90.000000 MHz"),  // clk_ddr UNCHANGED
.output_clock_frequency3("29.700000 MHz"),  // NEW = clk_pix
.phase_shift3("0 ps"),
.duty_cycle3(50),
// outclk port pack: {outclk_3, outclk_2, outclk_1, outclk_0}
```

```
f_pix = 1650 × 750 × 24 = 29_700_000 Hz exactly
```

### PIX24i — integer interim if fractional product-PLL rejected

```verilog
.fractional_vco_multiplier("false"),
.number_of_clocks(4),
.output_clock_frequency3("30.000000 MHz"),
// fps_eff = 30e6/1_237_500 ≈ 24.24 Hz (+1%)
```

### PIX60 — path to 720p60 (second grant, after PIX24 STA green)

```verilog
.fractional_vco_multiplier("true"),
.number_of_clocks(4),
.output_clock_frequency0("20.000000 MHz"),
.output_clock_frequency2("90.000000 MHz"),
.output_clock_frequency3("74.250000 MHz"),  // 1650×750×60
```

| Target | `clk_pix` | Min `PRESENT_PX_PER_CLK` | Fabric peak @20 | Balance |
|--------|----------:|-------------------------:|----------------:|:-------:|
| PIX24 | 29.70 | **2** | 40 Mpix/s | 1.35× |
| PIX60 | 74.25 | **4** | 80 Mpix/s | 1.08× |

**Not in this plan:** raising `clk_sys` or `clk_ddr`.

### Wiring (already scaffolded, macro OFF)

| Piece | Location | Default |
|-------|----------|---------|
| `present_core.clk_pix` port | `present_core.sv` | Plex ties to `clk_sys` |
| `present_npx_path.clk_pix` | not tied to `clk` | uses port |
| Bresenham rate-match | `present_pix_rate_match.sv` | only if `PRESENT_CLK_PIX_PLL` |
| FIFO sync sideband | `INCLUDE_SYNC` | 1 only if `PRESENT_CLK_PIX_PLL` |
| `CLK_VIDEO` / `CE_PIXEL` | `Plex.sv` | ship: `clk_sys` / `ce_pix` |
| Placeholder | `assign clk_pix = clk_sys` under ifdef | **replace with outclk_3 on grant** |

Macros: `PRESENT_MULTI_PIXEL` + `PRESENT_PX_PER_CLK=2` + `PRESENT_CLK_PIX_PLL` — **all OFF in QSF**.

---

## 2) CDC story (item 2) — extends `e0f23e5a`

### Topology when PIX24 applied

```
clk_sys 20 MHz ── beam + store + YUV N-wide + rate_match + FIFO wr
                      │
                      │  async_fifo (gray ptr + mem→rd_data_r false_path)
                      ▼
clk_pix 29.7 MHz ── FIFO rd + RGB hold + HS/VS/DE (sideband) → CLK_VIDEO
clk_ddr 90 MHz  ── unchanged frame-store fill (existing inventory)
```

### Crossings

| # | Crossing | New? | Protection | Risk if broken |
|---|----------|:----:|------------|----------------|
| 1 | `async_fifo` gray wr↔rd ptr | **Yes as load-bearing dual-clock** (module already dual-clock capable; today same-clock) | 2FF gray inside `async_fifo` — **timed**, not false-pathed | Pointer desync → corrupt RGB / tear |
| 2 | `async_fifo` `mem[]` → `rd_data_r` | Same mechanism, now **true** async | `Plex.sdc` `set_false_path` keepers only | Without cut: related-edge placement-fragile (known class on ddr↔sys FIFO) |
| 3 | Sync/blank with pixel | **New** | `INCLUDE_SYNC=1` packs `{vs,hs,vb,hb,r,g,b}` per word; blank inject on non-DE beam steps | Bare 2FF HS without pixel align → colour-fringe column / shear |
| 4 | Beam enable throttle | **New** (sys only) | `present_pix_rate_match` Bresenham so avg px rate = f_pix | Free-run beam finishes line in 41 µs vs 55 µs need → FIFO underrun mid-line |
| 5 | `clk_sys`↔`clk_ddr` | No | Existing inventory / gray / dual-port M10K | Unchanged by pix split |
| 6 | Whole `clk_sys`↔`clk_pix` false_path | **Forbidden** | — | Gate self-weakening |

Same-clock bring-up (Stage 0, multi-pixel ON, `PRESENT_CLK_PIX_PLL` OFF): crossings 1–2 collapse to one clock; 3–4 inactive (`INCLUDE_SYNC=0`, no rate_match).

### Mid-line FIFO underrun — what breaks (plain)

When `rd_empty` on `clk_pix` during active DE:

1. `present_npx_path` drops `out_ce`, forces RGB **black** for that tick (see module).
2. With `INCLUDE_SYNC=1`, **last sync flags are held** (not reset) so HS/VS do not X — but DE may still be active from sideband of prior word → **black pixel inserted in active video** (dark sparkle / intermittent black columns).
3. If underrun persists for many pix clocks, line appears **torn or sheared**; next full group realigns only if beam+rate_match catch up during blanking.
4. Root causes to treat as fails, not “soft”:
   - PPC too low (PIX24 needs ≥2; PIX60 ≥4)
   - Rate-match disabled while f_pix > f_sys
   - Store underrun (DDR) starving `fs_n_valid` so FIFO never fills
   - `in_ready` ignored / beam free-run

**Honest risk call:** the **risky** crossing is **#1+#4 together** — gray CDC is proven IP, but **rate balance + blank inject** is new integration surface. RGB-only FIFO without sideband (#3) would be worse (sync in wrong domain). Do not ship dual-clock without soak TB green (`test_present_npx_sync_sideband`) and post-fit hierarchy proving `u_mp_npx_path` / `u_mp_rate` survived.

Sim evidence (no STA claim):
- `test_present_npx_path_verilator` — beat conservation
- `test_present_npx_cdc_soak` — dual-clock RGB soak
- `test_present_npx_sync_sideband` — dual-clock @~20/29.7 with sync flags
- `test_present_pix_rate_match` — Bresenham |err|<0.2% over 10 ms

---

## 3) STA expectations — **pre-registered before fit** (item 3)

Parent scores `Plex.sta.rpt` after exclusive fit. **Negative slack = HARD FAIL.**  
These predictions are locked **now** so results are scored, not rationalised.

### 3.1 Stage 0 — multi-pixel ON, `clk_pix=clk_sys` (geometry fit)

| Check | Expect | FAIL if |
|-------|--------|---------|
| Fmax `clk_sys` (general[0]) | ≥ **20.0 MHz** | Fmax < 20.0 or setup slack < 0 on constrained sys paths |
| Fmax `clk_ddr` (general[2]) | ≥ **90.0 MHz** (shipping class; nostub often ~96–97) | setup slack < 0 on non-excluded ddr paths |
| `clk_sys` worst setup slack | ≥ 0 | any negative |
| `clk_ddr` worst setup slack | ≥ 0 | any negative |
| Related-edge sys↔ddr | still **5.556 ns** family (20/90) | relationship retconned without PLL change |
| Hierarchy | non-zero ALM/reg for `u_mp_timing`, `u_mp_beam`, `u_mp_npx_path` | row missing / zero (elision) |
| Multi-pixel Fmax headroom | **unknown** — may be tight vs 20 | if 20 ≤ Fmax < 23, note margin; if Fmax < 20 = FAIL |

**I do not predict** multi-pixel Fmax MHz to two decimals without a fit — that would be a guess. I predict the **pass/fail cut**: must close at the constrained 20 MHz.

### 3.2 Stage 1 — PIX24 applied (`PRESENT_CLK_PIX_PLL`, outclk_3=29.7)

| Check | Expect | FAIL if |
|-------|--------|---------|
| Fmax `clk_sys` | ≥ **20.0 MHz** | < 20 or neg slack |
| Fmax `clk_pix` (new general[3] or named) | ≥ **29.7 MHz** | < 29.7 or neg slack on pix cone |
| Fmax `clk_ddr` | ≥ **90.0 MHz** constrained | neg slack |
| Gray pointer paths sys↔pix | slack ≥ 0 (timed) | neg slack on gray/sync flops |
| `mem→rd_data_r` | remains false_path; **must not** appear as failing setup that we “fix” by widening cuts | new whole-domain false_path added |
| Hierarchy | + `u_mp_rate` non-zero when macro ON | elided rate_match |
| `number_of_clocks` | 4 in PLL | still 3 while claiming PIX24 |

### 3.3 Stage 2 — PIX60 (74.25) — later

| Check | Expect | FAIL if |
|-------|--------|---------|
| Fmax `clk_pix` | ≥ **74.25 MHz** | < 74.25 — **likely tight**; may need pix-domain pipeline |
| PPC | 4 | balance fail / underrun class on glass |

**Pre-registered miss handling:** if Stage 1 clk_pix Fmax is e.g. 40–60 MHz, that is a **path problem**, not a license to false_path. Fix serializer/hold cone. If clk_sys Fmax collapses below 20 with multi-pixel, cut PPC or pipeline YUV — **not** a sys overclock.

### 3.4 Machine-readable prereg

See `assets/clk_pix_sta_prereg.json` (this commit). Parent after fit:

```bash
make post-fit-timing STA_RPT=/path/Plex.sta.rpt; echo "true rc=$?"
make post-fit-timing-margin STA_RPT=/path/Plex.sta.rpt
make post-fit-hierarchy FIT_RPT=/path/Plex.fit.rpt
# Quote Fmax Summary lines for general[0], general[2], and pix out if present
```

---

## 4) Default OFF (item 4)

| Control | State |
|---------|-------|
| `PRESENT_MULTI_PIXEL` in QSF | **absent** |
| `PRESENT_CLK_PIX_PLL` in QSF | **absent** |
| `pll_0002` clocks | **3**, 20/90 |
| Product reset macros | bit-identical intent vs proven `d1b24e0c` class core |

Gates: `make clk-pix-pll-plan` fails if PLL gains outclk_3 while contract still `PROPOSED_NOT_APPLIED`.

---

## 5) Parent commands (box healthy)

```bash
# Pre-fit (build host, now)
make clk-pix-pll-plan
make fabric-clock-headroom
make present-720p-fit-contract
./tests/unit/test_present_pix_rate_match.sh; echo "true rc=$?"
./tests/unit/test_present_npx_sync_sideband.sh; echo "true rc=$?"
./tests/unit/test_present_npx_cdc_soak.sh; echo "true rc=$?"

# After Stage 0 or 1 fit (parent)
make post-fit-timing STA_RPT=...
make post-fit-hierarchy FIT_RPT=...
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
scripts/hdmi_capture_idle.sh /path/cap.png
```

Apply card: `.agent-work/w-clock/CLK_PIX_APPLY_CHECKLIST.md`.

---

## 6) One-line bottom line

**Separate `outclk_3 = 29.700000 MHz` as `clk_pix`; keep `clk_sys` at 20; CDC = async_fifo gray + mem false_path + sync sideband + Bresenham rate-match; STA must show Fmax_sys≥20, Fmax_pix≥29.7, slack≥0; all macros OFF until grant.**
