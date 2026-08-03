# PRE-REGISTER — PRESENT_CLK_PIX_PLL fit (before any fit)

**Base:** main `8fb5afe7` + this branch tip  
**Corner:** Slow 1100mV 100C Final  
**Ship product (flag OFF):** clk_sys=20, clk_ddr=90 — unchanged  
**Flag ON recipe:** PRESENT_CLK_PIX_PLL + Plex_clk_pix.sdc; default clk_pix=29.70  
**Optional:** PRESENT_CLK_PIX_74_25 → clk_pix=74.25 (higher risk)

## Predictions

| Config | clk_sys@20 setup≥0 | clk_ddr@90 | clk_pix Fmax | Expected Fmax owner (clk_sys) | PASS? |
|---|---|---|---|---|---|
| **OFF** (product) | YES | YES (≥90) | n/a (tied sys) | `slice_hdr_parser` `r_tc`→`residual_csum` (combo fold on main) | **PASS** |
| **ON 29.70** + MULTI_PIXEL PPC=1 | YES | YES | ≥29.7 on general[3] | clk_sys still **residual_csum**; clk_pix: `present_npx_path` unpack / CE path | clk_sys **PASS**; **rate FAIL** (20&lt;29.7 Mpix) — not a STA false green |
| **ON 29.70** + PPC=2 (future store) | YES | YES | ≥29.7 | residual_csum (sys); npx (pix) | **PASS** if both domains close |
| **ON 74.25** | YES | YES | ≥74.25 | pix domain likely owns worst path in present RGB | **FAIL or HIGH risk** — no MEASURED Fmax≥74 on present path |

`decode_stub` owns Fmax? **NO** (if yes → parent miss #18 class).

### Refutation / confirm evidence (one pass after fit)

```bash
quartus_sta -t scripts/l4_sta_dump_paths.tcl Plex Plex OUT/   # if present
# or report_timing path dumps including general[3]
scripts/sta_onepass_interrogation.sh OUT/Plex.sta.rpt OUT/clk_sys_sameclk_setup.txt
# Also require: Fmax(general[3]) printed; owner named; setup≥0 all domains
```

| Code | Miss if |
|---|---|
| M1 | clk_sys setup &lt; 0 or Fmax &lt; 20 |
| M2 | owner = decode_stub / placeholder |
| M3 | flag ON but general[3] missing / 0 MHz |
| M4 | clk_pix Fmax &lt; requested 29.7 or 74.25 |
| M5 | residual still combo and still owns with &lt;5 ns slack @20 |
| M6 | async group omitted → false related-edge fails on FIFO gray |

### Prior MEASURED (different netlists — do not transfer)

- nostub: clk_sys Fmax 32.59 MHz, owner residual_csum, data delay 30.062 ns  
- stub-in: 23.46 MHz owner decode_stub  
- slot11 report: Fmax 25.09, setup −2.137 (that fit’s constraints)

**Honest wall:** 74.25 MHz present domain has **no** in-repo STA proof. 29.70 MHz is the aggressive-but-grounded first rung matching existing `MP_CLK_PIX_HZ`.
