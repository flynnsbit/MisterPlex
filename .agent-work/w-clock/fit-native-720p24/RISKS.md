# Risks — native 720p ~24 Hz beam fit

## BLOCKER-CDC-24-90 (NEW — closes prior unquantified hazard)
clk_sys=24 / clk_ddr=90 → min related setup Δ **2.778 ns** (edge family 4:15).  
Measured meta data delay **~3.5–4.9 ns**. Expect **related-edge SETUP HARD_FAIL**  
on y_line/c_line→v1 class (same class as inventory 25 MHz kill).  
**Primary fit uses 30 MHz (3:1), not 24.** Detail: `CDC_RATIO_24_90_AUDIT.md`.

## R1 — 32.59 is prior netlist only
fit-nostub-chrome ≠ L4 present + native DE. Fmax may fall below 30.

## R2 — L4 not on → false green
640×480 with 30 MHz is not native 720p24.

## R3 — Hold at 3:1
30/90 setup easy; **hold** same-edge must pass (inventory).

## R4 — Throughput RD-TP
input_fifo AW=2; line prep vs faster sys scan at 1280.

## R5 — Fabric decode not in 32.59 sample

## R6 — Parallel structural edits mid-fit
