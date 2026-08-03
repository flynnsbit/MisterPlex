# STA pass criteria — native ~24 Hz beam (PRIMARY = 30 MHz CDC path)

## Corner that COUNTS
**Slow 1100mV 100C Final** only. Fast-only → reject.

## PRIMARY mode (release candidate)

| ID | Assertion |
|----|-----------|
| C1 | clk_sys **30.000 MHz** (period 33.333 ns) |
| C2 | clk_ddr **90.000 MHz** |
| C3 | Fmax(clk_sys) **≥ 30.000** MHz |
| C4 | Fmax(clk_ddr) **≥ 90** |
| C5 | Setup slack all clocks **≥ 0** (Slow 1100mV 100C) |
| C6 | **Hold** slack **≥ 0** (3:1 same-edge hold family — mandatory) |
| C7 | Related clk_sys↔clk_ddr setup/hold **≥ 0**; meta `*_line*→*_v1*` class must appear timed with slack≥0 |
| P1–P2 | Path owner **named**; **not** `decode_stub` |
| P5 | Fail if Fmax row without extractable From/To |
| H1–H3 | Beam DE **1280×720**, H≈1312, V≈953 survive hierarchy |

```bash
make post-fit-timing STA_RPT=/path/to/Plex.sta.rpt; echo "true rc=$?"
```

## EXPERIMENTAL 24 MHz mode (blocked)

Only after CDC meta fix. Additional assert:
- Clocks panel min related Δ documented; **no** setup rel &lt; 5 ns with data delay &gt; rel  
- Or meta path removed from related-edge class  

Fmax floor if ever run: ≥ 24.000 MHz — **insufficient alone**.

## 32.59 prior
Fmax 32.59 from fit-nostub-chrome does **not** transfer. New netlist may fail 30.
