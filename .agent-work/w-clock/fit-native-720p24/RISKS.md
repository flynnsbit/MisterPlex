# Risk list — why paper 32.59 does not auto-pass native 720p24

## R1 — Different netlist than Fmax sample (CRITICAL)
**32.59 MHz** was measured on **fit-nostub-chrome** (`c74c6863`) — ARM-present,
stub-out, **not** today’s main+w-osd L4 present path, **not** native 1280 beam RTL,
**not** clk_sys=24.

Adding/enabling present path, geom mux/latch, 1280 DE, B20 logic, or any decode
change **moves placement and the critical path**. Paper margin is a **prior**, not
a guarantee.

## R2 — L4 not actually on (false STA green)
If `FRAME_W/H` stay 640×480 or beam stays behind a dead ifdef, STA may pass 24 MHz
on a **480p** netlist while the user-visible mode is unchanged.  
**Hierarchy + capture must prove 1280 DE** (H1–H3).

## R3 — L2 dead code / strip
Modules in `files.qip` with **INSTANTIATED=0** are stripped — they do not stress Fmax
and do not deliver function. Parent already saw mux/latch/window at 0 refs.

## R4 — CDC ratio 24:90 = 4:15
Not the clean 3:1 of 30/90. Related-edge setup/hold can surprise; async_fifo cut is
only mem→rd_data_r. Other sys↔ddr paths stay timed. Prior 20/90 had fragile
related-edge holds (product SDC comments).

## R5 — residual_csum keep-cone still present
Prior nostub owner is **real** product logic. If it worsens under new place/route,
Fmax can fall below 24. Cutting keep without parent residual-protocol grant is
forbidden gate-weakening.

## R6 — Fabric H.264 not in the 32.59 netlist
If this fit accidentally includes heavy decode, Fmax is **unmeasured**. Keep
nostub/ARM-present scope unless parent explicitly combines (not recommended).

## R7 — PLL string vs actual VCO
We set frequency strings; Quartus chooses counters. Confirm STA clocks panel shows
**exactly 24.000 / 90.000** (not a nearby fractional).

## R8 — Beam totals not SDC
H=1312 V=762 are RTL/runtime. Wrong defaults → wrong fps even if STA passes.

## R9 — ascal / HDMI still ~60
Core ~24 Hz into ascal; glass 60. Capture must not demand panel-native 24 Hz.
Judder is ascal class, not Bresenham (1:1 content).

## R10 — Collision with w-osd structural edits
PLL + QSF + present instantiate must be **one sequenced fit**, not parallel edits
to the same files mid-compile.
