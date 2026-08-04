# PRE-REGISTER Fmax — w-clock @ base 956e05d7 / branch w-clock-720p-plan

## Pre-register (before digest)

| Clock / scenario | Predicted Fmax (Slow 1100mV 100C) | Predicted owner | Pass @ required |
|------------------|----------------------------------|-----------------|-----------------|
| clk_sys @20 stub-class | **22.5–23.5 MHz** | unnamed in plain STA | PASS slack@20 |
| clk_sys @24 stub-class | same ~23.2 | same | **FAIL** |
| clk_sys nostub-class | **30–35 MHz** | residual_csum if present | PASS@24 possible |
| clk_pix 29.70 | **≥40 MHz** | present_npx_path unpack | PASS@29.70 if light |
| clk_ddr 90 | **~90–96 MHz** | DDR bridge | PASS@90 |

## Post-measure (retained `output_files/Plex.sta.rpt`)

| Metric | Value | Delta vs PRE-REG |
|--------|-------|------------------|
| clk_sys Restricted Fmax | **23.17 MHz** | **HIT** (in 22.5–23.5) |
| clk_sys setup slack @20 | **+0.849 ns** | HIT PASS@20 |
| clk_ddr Restricted Fmax | **93.62 MHz** | HIT |
| clk_sys @24 gate | **rc=1** (23.17&lt;24) | **HIT FAIL prediction** |
| clk_pix Fmax | absent (macro OFF) | unknown until fit |
| Path owner module name | **not in plain STA export** | PRE-REG owner still unconfirmed |

Owner naming requires timing path detail / `report_timing` — plain Fmax Summary does not print hierarchical endpoint owners. Check that settles it: parent fit + `report_timing -npaths 10 -detail full_path` on general[0].
