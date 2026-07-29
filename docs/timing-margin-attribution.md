# clk_ddr margin attribution (integ tip `ef3a122` / STA 2026-07-29)

## Context

Post-fit of `feat/disp-fmt` tip after ~fifteen simulation-only decode merges
closed timing with **TNS=0**, but **clk_ddr setup** eroded vs the **wtime4**
reference:

| metric | wtime4 | integ tip | Δ |
|--------|--------|-----------|---|
| clk_ddr setup (general[2]) | **+0.284 ns** | **+0.258 ns** | **−0.026 ns** |
| clk_sys hold (general[0]) | **+0.244 ns** | **+0.240 ns** | **−0.004 ns** |
| TNS (all sections) | 0 | 0 | 0 |

Raw STA (`Plex.sta.rpt` Setup/Hold Summary):

```
; Setup Summary
; emu|pll|...|general[2]...divclk  ; 0.258  ; 0.000
; emu|pll|...|general[0]...divclk  ; 0.712  ; 0.000

; Hold Summary
; emu|pll|...|general[0]...divclk  ; 0.240  ; 0.000
; emu|pll|...|general[2]...divclk  ; 0.311  ; 0.000
```

Fmax (same report): clk_sys **23.27 MHz**, clk_ddr **92.14 MHz** (required 90 MHz).

## Can we name endpoints?

**No.** The exported STA is **summary-only** (1011 lines). Searches for
`From Node`, `To Node`, `Path #1`, and `Data Arrival Path` return **zero** hits
in `Plex.sta.rpt`, `Plex.fit.rpt`, and `compile.log`.

So the honest finding is:

> **Erosion is unattributable to named RTL endpoints from the artifacts we have.
> It must be treated as a domain budget problem, not a single-path fix.**

A future fit that enables detailed path reporting (`report_timing -npaths N`
/ full TimeQuest path dump in the remote build) could upgrade this from
domain-level to endpoint-level. That would require a deliberate fit recipe
change — not a re-parse of the current STA.

## Binding constraint

| domain | worst setup | Fmax | notes |
|--------|-------------|------|-------|
| **clk_ddr** (90 MHz) | **0.258 ns** (tightest setup) | 92.14 MHz (~2.4% headroom) | **Binding for setup closure risk** |
| clk_sys | 0.712 ns | 23.27 MHz | Looser setup slack; hold is the wtime4 hold watchpoint |

Hierarchy sizes (post-fit, not path delays): `stream_path` dominates ALMs/DSPs
(clk_sys decode), `ddr_frame_store` is the large clk_ddr consumer. Size alone
does **not** prove which path ate 26 ps.

## Gate

`scripts/check_timing_margin.py` + `assets/timing_margin_baseline.json` (wtime4)
fail when tracked margin regresses more than **50 ps** from reference, or when
TNS/slack go negative. Missing/malformed STA → **rc=77 SKIP-NOT-PASS**.

Wired into `make post-fit-timing-margin`, `scripts/build_rbf_remote.sh` after
negative-slack check, and `make unit` via mutation test
`tests/unit/test_timing_margin_gate.sh`.

## Trend / mitigation judgement

At **−0.026 ns per ~15 decode merges** (~1.7 ps/merge if linear — it will not
be linear):

- Remaining budget to the gate floor (0.284 − 0.05 = **0.234**): **0.024 ns**
  from current 0.258 → roughly **one more similar batch** before the **margin
  gate** trips (not before Quartus fails).
- Remaining budget to hard zero: **0.258 ns** → on a naive linear model tens of
  batches, but **routing cliffs** mean the next heavy clk_ddr touch can consume
  the rest at once.

**First mitigation to reach for (in order):**

1. **Keep the margin gate red-blocking** so silent eat cannot ship as BUILD_OK.
2. **Enable detailed `report_timing` on clk_ddr** in the remote fit recipe so the
   next erosion names endpoints.
3. **clk_ddr path work only after named paths exist** — register retiming /
   pipeline on `ddr_frame_store` / present DDR read, not speculative decode cuts
   on clk_sys.
4. If still tight: lower non-critical logic on clk_ddr or split domains — last
   resort before dropping required Fmax.
