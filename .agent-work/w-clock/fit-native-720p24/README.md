# Native 720p24 fit handoff kit (w-clock)

**Ship-proof until parent fit: NO**  
**Do not run Quartus from this lane.**

| File | Role |
|------|------|
| `PLL_EDIT.md` | Concrete pll_0002.v out0 20→24 (not applied here) |
| `Plex_native720p24.sdc` | Real SDC text for the grant |
| `STA_PASS_CRITERIA.md` | Corner, Fmax, path owner, hierarchy asserts |
| `sta_pass_criteria.json` | Machine-readable for w-fitgate |
| `RISKS.md` | Why 32.59 does not auto-transfer |
| `LADDER_VERIFY.md` | L0–L4 per module (pinned refs) |

### Preferred mode
- clk_sys **24.000 MHz**, clk_ddr **90.000 MHz**
- DE **1280×720**, H_TOTAL **1312**, V_TOTAL **762** → **24.006 Hz**
- Content 24/1 → 1:1 core cadence; HDMI ~60 via ascal
- Corner **Slow 1100mV 100C Final**; Fmax(clk_sys) ≥ 24
