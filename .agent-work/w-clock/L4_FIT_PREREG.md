# PRE-REGISTER — single fit slot (locked BEFORE fit)

**Pin main base:** `035fae51b7d36160f865efcee217a6fde49532f8`  
**Branch tip:** see commit after land  
**Corner:** Slow 1100mV 100C Final  
**Ship PLL:** clk_sys 20.000 MHz, clk_ddr 90.000 MHz (PARKED — no PLL edit in this fit)  
**Instrument:** `scripts/sta_onepass_interrogation.sh STA_RPT [PATH_DUMP]`  
**Path dump:** `quartus_sta -t scripts/l4_sta_dump_paths.tcl Plex Plex OUT/`

| Label | Macros |
|---|---|
| **OFF** | FRAME 640×480; `PLEX_PRESENT_720P_L4` commented (product default) |
| **ON** | `PLEX_PRESENT_720P_L4=1` `FABRIC_NATIVE_720P_GEOM=1` FRAME 1280×720 |

## PREDICTION (hold me to this)

| Case | Fmax vs 20 MHz | setup≥0 @20 | Expected Fmax band | Critical-path owner | PASS@ship 20 MHz |
|---|---|---|---|---|---|
| **OFF** (default) | ≥20 | YES | 28–34 MHz class (paper) | `slice_hdr_parser` `r_tc`→`residual_csum` | **PASS** |
| **ON** (L4 content) | ≥20 | YES | 24–32 MHz (paper) | **same residual_csum** primary; watch `present_content_window` `store_x_prod` | **PASS** |
| ON + this branch csum_acc | ≥20 | YES | unknown until fit | **NOT** residual_csum if fix in tree | PASS@20 |

`decode_stub` owns Fmax? **NO**. If yes → miss class parent #18.

### Miss codes (publish if any)

| Code | Condition |
|---|---|
| M1 | setup slack < 0 or Fmax < 20 on clk_sys |
| M2 | owner ≠ residual_csum without csum_acc fix in tree |
| M3 | owner is decode_stub / placeholder |
| M4 | y_line / related-edge negative slack |
| M5 | clk_ddr Fmax < 90 |
| M6 | csum_acc fix in tree but residual still owns |
| M7 | Fmax band off prediction by >5 MHz |

### Prior MEASURED (different netlist — do not transfer)

- nostub path dump: residual data delay **30.062 ns**, path slack +19.3 ns @ 50 ns period class  
- slot11 `Plex.sta.rpt`: clk_sys Fmax **25.09**, setup **−2.137** (FAIL vs 20 only if that report’s constraint period ≠ 50 ns — interrogate live fit)  
- Label every number with **which report / which netlist**.

### Parent extract (one pass)

```bash
quartus_sta -t scripts/l4_sta_dump_paths.tcl Plex Plex OUT/
scripts/sta_onepass_interrogation.sh OUT/Plex.sta.rpt OUT/clk_sys_sameclk_setup.txt
# cmd; echo "true rc=$?"
```
