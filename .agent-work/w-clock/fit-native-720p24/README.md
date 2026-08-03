# Native 720p24 fit handoff (CDC-revised)

**PRIMARY:** clk_sys **30 MHz** + H=1312 V=953 (≈24 Hz content), CDC **3:1**  
**24 MHz PLL DEMOTES to experimental** — BLOCKER related-edge 2.778 ns  

| File | Role |
|------|------|
| `CDC_RATIO_24_90_AUDIT.md` | **Read first** — crossing table + blocker |
| `PLL_EDIT.md` | out0 → **30.000000** MHz (not applied) |
| `Plex_native720p24_cdc30.sdc` | **Primary SDC** |
| `Plex_native720p24.sdc` | Experimental 24 MHz only |
| `STA_PASS_CRITERIA.md` / `.json` | Slow 1100mV 100C; Fmax≥30; hold≥0 |
| `RISKS.md` | 32.59 prior; CDC blocker |

No fit from this lane. No PLL apply.
