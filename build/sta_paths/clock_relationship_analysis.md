# Clock Relationship Analysis — general[0].gpll vs general[2].gpll

**Author:** w-cap  
**Date:** 2026-07-27  
**SHA:** a6b1124 (feat/cap-device)  
**Status:** RAW FACTS — interpretation follows facts

---

## 1. PLL Configuration (Source: `rtl/pll/pll_0002.v`)

Single PLL instance `pll_inst` (type: "General", subtype: "General").  
Reference clock: **50.000 MHz** (FPGA_CLK2_50 via CLK_50M).

| Counter | Quartus Name       | Frequency   | Phase | Connected To          | Role                 |
|---------|--------------------|-------------|-------|-----------------------|----------------------|
| C0      | general[0].gpll    | 20.000 MHz  | 0 ps  | `clk_sys` (Plex.sv:215) | Core system clock   |
| C1      | general[1].gpll    | 142.000 MHz | 0 ps  | `clk_sdram` (Plex.sv:216) | SDRAM controller  |
| C2      | general[2].gpll    | 90.000 MHz  | 0 ps  | `clk_ddr` (Plex.sv:217) | DDR bridge clock    |

*(C1 frequency set by QSF macro `SDRAM_CLK_142=1`; default is 100 MHz.)*

All three outputs come from **the same physical PLL**, fed by the same 50 MHz reference.

## 2. SDC Constraints (Sources: `sys/sys_top.sdc`, `Plex.sdc`)

- `derive_pll_clocks` automatically creates clock constraints for all PLL outputs.
- `Plex.sdc` contains NO core-specific constraints — only `derive_pll_clocks` and
  `derive_clock_uncertainty`.
- `sys_top.sdc` groups ALL core PLL outputs in ONE exclusive group:
  ```
  -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
  ```
  This means general[0], general[1], and general[2] are **mutually timed** (correct).
  They are exclusive only with respect to OTHER PLLs (pll_hdmi, pll_audio, etc.).

## 3. VERDICT: Intended Relationship

**SYNCHRONOUS.** Both clocks originate from the same PLL, same reference.
Quartus correctly derives them as related clocks and performs inter-clock
setup/hold analysis. No constraint override is needed or appropriate.

The worst-case setup relationship between 20 MHz and 90 MHz from the same
PLL is **5.556 ns** — the smallest positive edge gap in their combined
100 ns superperiod:

```
20 MHz edges (50 ns period):   0     50    100
90 MHz edges (11.111 ns):      0  11.111  22.222  33.333  44.444  55.556  ...

PATH 1 (90→20): launch 44.444, latch 50.000 → relationship = 5.556 ns  ✓
PATH 2 (20→90): launch 50.000, latch 55.556 → relationship = 5.556 ns  ✓
```

## 4. Path Analysis

### PATH 1 — slack -2.137 ns, 7 logic levels

```
FROM: sysmem_lite|sysmem_HPS_fpga_interfaces|f2sdram~FF_1937
  Clock: general[2].gpll  (clk_ddr, 90 MHz)

TO:   emu|stream_path:spath|ddr_bitstream_reader:ddr_stream|current_session[51]
  Clock: general[0].gpll  (clk_sys, 20 MHz)

Relationship: 5.556 ns    Clock skew: -1.392 ns    Data delay: 6.181 ns
Required: 57.546 ns       Arrival: 59.683 ns       TNS: -407.873 ns
```

**Signal chain:** f2sdram register (90 MHz) → DDRAM_DOUT/DDRAM_DOUT_READY
  → ddr_bus_arbiter combinational logic (m1_dout_ready = DDRAM_DOUT_READY & rsp_active & rsp_owner_m1)
  → stream_path → ddr_bitstream_reader internal logic → current_session[51] register (20 MHz)

**The arbiter sits on clk_sys (20 MHz) but mixes DDRAM_DOUT_READY from the
f2sdram bridge (90 MHz) with rsp_active/rsp_owner_m1 (20 MHz) in a
combinational AND gate.** The result has no clean clock domain.

### PATH 2 — slack -1.346 ns, 4 logic levels

```
FROM: emu|ddr_bus_arbiter:ddr_arb|rsp_left[6]
  Clock: general[0].gpll  (clk_sys, 20 MHz)

TO:   emu|present_core:present|ddr_frame_store:fstore|y_valid[7]
  Clock: general[2].gpll  (clk_ddr, 90 MHz)

Relationship: 5.555 ns    Clock skew: -0.995 ns    Data delay: 5.786 ns
Required: 62.955 ns       Arrival: 64.301 ns       TNS: -183.170 ns
```

**Signal chain:** arbiter rsp_left[6] register (20 MHz)
  → rsp_active → m0_busy or m0_dout_ready (combinational, mixed-domain)
  → present_core wire pass-through → ddr_frame_store internal logic
  → y_valid[7] register (90 MHz, `always @(posedge clk_ddr)` at line 601)

**Note:** The frame store has a proper 2-flop synchronizer for the
READ direction (y_valid → y_valid_v1 → y_valid_v2, clk_ddr→clk_sys,
lines 329-330). But PATH 2 is the WRITE direction — 20→90 MHz —
and has NO synchronization.

## 5. Root Cause

The `ddr_bus_arbiter` is instantiated on `clk_sys` (20 MHz) at Plex.sv:783:
```verilog
ddr_bus_arbiter ddr_arb (
    .clk(clk_sys),    // ← 20 MHz
    ...
```

But it drives/receives DDRAM interface signals that are latched by the
f2sdram bridge at `DDRAM_CLK = clk_ddr` (90 MHz). The f2sdram clock
assignment chain:

```
pll outclk_2 (90 MHz) → clk_ddr → present_core → ddr_frame_store
  → assign DDRAM_CLK = clk_ddr (line 114) → Plex.sv DDRAM_CLK port
  → sys_top.v ram_clk → sysmem f2sdram ram1_clk
```

**The arbiter produces mixed-domain combinational outputs:**
```verilog
// In ddr_bus_arbiter.sv — all combinational, no registers at boundary
assign m0_busy       = DDRAM_BUSY | grant_m1 | (rsp_active & rsp_owner_m1);
assign m0_dout_ready = DDRAM_DOUT_READY & rsp_active & !rsp_owner_m1;
// DDRAM_BUSY/DOUT_READY: from f2sdram at 90 MHz
// rsp_active, grant_m1, rsp_owner_m1: from arbiter at 20 MHz
```

## 6. What set_clock_groups -asynchronous Would Do (DO NOT APPLY)

Adding `-asynchronous` between general[0] and general[2] would:

1. **Instantly close timing** — both failing paths would be excluded from analysis.
2. **Be factually wrong** — these clocks ARE synchronous (same PLL, same reference).
3. **Hide real design defects** — the mixed-domain combinational paths would remain,
   with data corruption at the domain boundary going undetected by STA.
4. **Candidate 3 for the frame-store stall (PATH 2) would become invisible to analysis.**

## 7. Fix Options (for RTL owners, not w-cap)

| Option | Description | Owner |
|--------|-------------|-------|
| A | Move arbiter to `clk_ddr` (90 MHz). Eliminates arbiter-side crossing but creates new crossings to stream_path/present_core (both on clk_sys). | w-a3 |
| B | Add pipeline register stages at the domain boundary. Single registered stage at each crossing point should fit in 5.556 ns. | w-a3 + w-rel |
| C | `set_multicycle_path -setup 2` on these specific paths if multi-cycle latency is tolerable. Requires RTL confirmation that the handshake protocol can absorb the extra cycle. | w-a3 + w-rel verify, w-cap applies |
| D | Run everything at one clock (either all 90 MHz or all 20 MHz). Major rearchitecture. | All |

**Option B is likely simplest.** The mixed-domain combinational AND gates in the
arbiter (m0_busy, m0_dout_ready, m1_busy, m1_dout_ready) are the immediate
problem. Registering those outputs in the destination clock domain before use
would cut both paths to single-register crossings.

## 8. Evidence for Stall Candidate 3

PATH 2 lands at `y_valid[7]` — the line-valid flag in the frame store's DDR
state machine. If setup timing is genuinely unmet on this path, the `y_valid`
register could sample an incorrect value (metastability or wrong data), causing
the DDR FSM to:
- Skip line fills it should execute (stall)
- Re-fill lines that are already valid (wasted bandwidth)
- Corrupt the valid/bank tracking (persistent stall requiring reset)

This is a **complete standalone explanation** for the observed
published-then-stalled state (PLXF magic present, has_frame=0).
The timing violation does not require the async-FIFO comb loop or
the bank-race to also be broken — it is sufficient on its own.

---

*This analysis is based on source inspection. Confirmation requires a
post-fit netlist timing report from the next provenance-correct build.*
