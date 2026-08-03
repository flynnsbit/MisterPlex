# STA pass criteria — native 720p24 fit (w-fitgate / parent)

## Corner that COUNTS (mandatory)

| Field | Required value |
|-------|----------------|
| **Model** | **Slow 1100mV 100C Model** |
| **Timing models** | **Final** |
| **Device** | 5CSEBA6U23I7 (DE10-Nano class) |

If the report only shows **Fast** / typical / 0C numbers → **DO NOT PASS**.  
Record Fast as advisory only.

Evidence location in Quartus STA: panel header / “Operating conditions” /  
`Slow 1100mV 100C` in path reports (same class as nostub dump
`.agent-work/w-clock/nostub-path-dump/clk_sys_emu_sameclk.txt`).

## Clock assertions

| ID | Assertion | How to check |
|----|-----------|--------------|
| **C1** | `clk_sys` constrained period corresponds to **24.000 MHz** (41.667 ns) | Clocks panel / Fmax Summary clock name matching `*general[0]*divclk*` or emu\|pll path |
| **C2** | `clk_ddr` remains **90.000 MHz** | same, `general[2]` |
| **C3** | Fmax Summary **Fmax(clk_sys) ≥ 24.000 MHz** | `Plex.sta.rpt` “Fmax Summary” row for clk_sys |
| **C4** | Fmax Summary **Fmax(clk_ddr) ≥ 90.000 MHz** | same |
| **C5** | Setup slack for clk_sys domain **≥ 0** at Slow 1100mV 100C | Setup Summary; `make post-fit-timing STA_RPT=...` rc=0 |
| **C6** | Hold slack clk_sys and clk_ddr **≥ 0** | Hold Summary; same gate |
| **C7** | Related clk_sys↔clk_ddr setup/hold **≥ 0** (no whole-domain false_path) | Multi-corner; inspect failing paths if any |

## Path-owner assertions (w-fitgate)

| ID | Assertion |
|----|-----------|
| **P1** | Critical path **From/To** for binding clk_sys setup **must be named** (not empty) |
| **P2** | Path owner **must NOT** be `decode_stub` hierarchy |
| **P3** | If Fmax is within **10% of 24 MHz** (Fmax < 26.4), path From/To must be quoted in the fit receipt |
| **P4** | Prefer reporting top path module: expect possible `slice_hdr_parser` / `residual_csum` (prior nostub owner) — **not a pass requirement**, only identification |
| **P5** | FAIL fitgate if “Fmax Summary” exists but **no** detailed path panel / From-To can be extracted |

## Beam / netlist assertions (post-fit hierarchy — separate gate)

| ID | Assertion |
|----|-----------|
| **H1** | `present_beam_content_de` or native 1280 beam **survives** fit (not stripped) |
| **H2** | Effective DE **1280×720** (parameters or kept registers) |
| **H3** | H_TOTAL/V_TOTAL class **1312 / 762** (or documented Bresenham pair) — if only 640×480 remains, **L4 FAIL** regardless of STA |
| **H4** | `PRESENT_BEAM_960` must **not** force 960 max if this fit is native 1280 |

## Commands (parent)

```bash
# After fit produces Plex.sta.rpt:
make post-fit-timing STA_RPT=/path/to/Plex.sta.rpt
echo "true rc=$?"

# Optional margin vs baseline (may need baseline refresh for 24 MHz):
# make post-fit-timing-margin STA_RPT=...

# PLL string vs STA:
python3 scripts/check_pll_clock_contract.py --sta-rpt /path/to/Plex.sta.rpt
echo "true rc=$?"
```

## PASS bundle

**PASS** only if **all** of: C1–C7, P1–P2, P5, H1–H3, corner = Slow 1100mV 100C Final,  
NEW_RBF ∉ banned set, ONE menu deploy, parent HDMI capture shows non-black 1280-class  
activity with unique content cadence ~24 (not ~20.7).

**Soft-skip / UNSCORED ≠ PASS.**
